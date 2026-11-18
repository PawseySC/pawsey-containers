import os
from datetime import datetime
from time import time
import argparse
import numpy as np
import random

import torch
import torch.multiprocessing as mp
import torch.nn as nn
import torch.distributed as dist
from torch.utils.data import Dataset, DataLoader
from torch.utils.data.distributed import DistributedSampler
from torch.nn.parallel import DistributedDataParallel as DDP
from torchvision.datasets import MNIST
from torchvision.datasets import FakeData
from torchvision.transforms import ToTensor
import torchvision.transforms.functional as TF

class StructuredFakeMNIST(Dataset):
    def __init__(self, size=10000, image_size=(1, 28, 28), num_classes=10, transform=None):
        self.size = size
        self.image_size = image_size
        self.num_classes = num_classes
        self.transform = transform

    def __len__(self):
        return self.size

    def __getitem__(self, idx):
        img = np.zeros(self.image_size, dtype=np.float32)
        label = idx % self.num_classes

        # Add pattern with some intra-class variability
        if label == 0:
            self._draw_dot(img, 14 + self._jitter(), 14 + self._jitter())
        elif label == 1:
            self._draw_vertical_line(img, col=14 + self._jitter())
        elif label == 2:
            self._draw_horizontal_line(img, row=14 + self._jitter())
        elif label == 3:
            self._draw_diagonal_line(img)
        elif label == 4:
            self._draw_square(img, 10 + self._jitter(), 10 + self._jitter(), size=6 + self._jitter(1))
        elif label == 5:
            self._draw_cross(img)
        elif label == 6:
            self._draw_circle(img, 14 + self._jitter(), 14 + self._jitter(), radius=4 + self._jitter(1))
        elif label == 7:
            self._draw_L_shape(img)
        elif label == 8:
            self._draw_checker(img)
        elif label == 9:
            self._draw_random_patch(img)

        # Convert to torch Tensor
        image_tensor = torch.tensor(img)

        # Apply affine transformation: scale, translate, rotate
        image_tensor = TF.to_pil_image(image_tensor)
        angle = random.uniform(-20, 20)  # degrees
        translate = (random.randint(-2, 2), random.randint(-2, 2))
        scale = random.uniform(0.9, 1.1)
        shear = random.uniform(-10, 10)

        image_tensor = TF.affine(image_tensor, angle=angle, translate=translate, scale=scale, shear=shear)

        # Convert back to tensor and normalize
        image_tensor = TF.to_tensor(image_tensor)

        # Add Gaussian noise
        noise = torch.randn_like(image_tensor) * 0.1
        image_tensor = torch.clamp(image_tensor + noise, 0.0, 1.0)

        if self.transform:
            image_tensor = self.transform(image_tensor)

        return image_tensor, label

    def _jitter(self, max_offset=2):
        return random.randint(-max_offset, max_offset)

    def _draw_dot(self, img, x, y):
        img[0, y % 28, x % 28] = 1.0

    def _draw_vertical_line(self, img, col):
        for row in range(28):
            if random.random() > 0.1:
                img[0, row, col % 28] = 1.0

    def _draw_horizontal_line(self, img, row):
        for col in range(28):
            if random.random() > 0.1:
                img[0, row % 28, col] = 1.0

    def _draw_diagonal_line(self, img):
        for i in range(28):
            if random.random() > 0.1:
                img[0, i, i] = 1.0

    def _draw_square(self, img, x, y, size=6):
        for i in range(size):
            for j in range(size):
                if random.random() > 0.2:
                    img[0, (y+i)%28, (x+j)%28] = 1.0

    def _draw_cross(self, img):
        for i in range(28):
            if random.random() > 0.1:
                img[0, i, 14] = 1.0
            if random.random() > 0.1:
                img[0, 14, i] = 1.0

    def _draw_circle(self, img, cx, cy, radius=5):
        for x in range(28):
            for y in range(28):
                if abs(((x - cx)**2 + (y - cy)**2)**0.5 - radius) < 1.5:
                    if random.random() > 0.1:
                        img[0, y, x] = 1.0

    def _draw_L_shape(self, img):
        for i in range(10, 20):
            if random.random() > 0.1:
                img[0, i, 10] = 1.0
        for j in range(10, 18):
            if random.random() > 0.1:
                img[0, 19, j] = 1.0

    def _draw_checker(self, img):
        for i in range(0, 28, 4):
            for j in range(0, 28, 4):
                if (i + j) % 8 == 0 and random.random() > 0.2:
                    img[0, i:i+2, j:j+2] = 1.0

    def _draw_random_patch(self, img):
        x = random.randint(0, 24)
        y = random.randint(0, 24)
        patch = np.random.rand(4, 4).astype(np.float32)
        img[0, y:y+4, x:x+4] = patch



# Neural network model to predict which number an image represents
class NeuralNetwork(nn.Module):
    def __init__(self, num_classes = 10):
        super().__init__()
        self.layer1 = nn.Sequential(
            nn.Conv2d(1, 16, kernel_size=5, stride=1, padding=2),
            nn.BatchNorm2d(16),
            nn.ReLU(),
            nn.MaxPool2d(kernel_size=2, stride=2))
        self.layer2 = nn.Sequential(
            nn.Conv2d(16, 32, kernel_size=5, stride=1, padding=2),
            nn.BatchNorm2d(32),
            nn.ReLU(),
            nn.MaxPool2d(kernel_size=2, stride=2))
        self.fc = nn.Linear(7*7*32, num_classes)

    def forward(self, x):
        out = self.layer1(x)
        out = self.layer2(out)
        out = out.reshape(out.size(0), -1)
        out = self.fc(out)
        return out


def parse_args():
    
    parser = argparse.ArgumentParser()
    parser.add_argument('-b', '--batch_size', default = 512, type = int,
        help = 'Batch size. It will be divided into mini-batches for each worker')
    parser.add_argument('-e', '--epochs', default = 15, type = int, metavar = 'N',
        help = 'Number of total epochs to run')
    args = parser.parse_args()

    return args.batch_size, args.epochs


def get_data():
    # Get separate training and validation data sets
    training_data = StructuredFakeMNIST(60000)
    validation_data = StructuredFakeMNIST(10000)

    return training_data, validation_data


def train_and_validate(nepochs, batch_size, train_dataset, validate_dataset):
    
    # Initialise the process group
    dist.init_process_group(backend = 'nccl')#, init_method = 'env://', world_size = size, rank = rank)

    # Define and distribute model
    local_rank = int(os.environ['LOCAL_RANK'])
    torch.cuda.set_device(local_rank)
    gpu = torch.device('cuda')
    model = NeuralNetwork().to(gpu)
    model = DDP(model, device_ids = [local_rank])

    loss_fn = nn.CrossEntropyLoss().to(gpu)
    opt = torch.optim.SGD(model.parameters(), lr = 1e-3)

    # Partition training dataset among GPUs and load the data for each GPU
    train_sampler = DistributedSampler(train_dataset)
    train_loader = DataLoader(train_dataset, batch_size, shuffle = False, num_workers = 4, pin_memory = True, sampler = train_sampler, persistent_workers = True)

    # Parittion validation dataset among GPUs and load the data for each GPU
    validate_sampler = DistributedSampler(validate_dataset, shuffle = False)
    validate_loader = DataLoader(validate_dataset, batch_size, shuffle = False, num_workers = 4, pin_memory = True, sampler = validate_sampler, persistent_workers = True)

    # Print statistics, etc. on root rank only
    root_rank = dist.get_rank() == 0

    # Begin training and validation, recording start time
    if root_rank:
        start = datetime.now()
    total_train_step = len(train_loader)
    total_val_step = len(validate_loader)
    N = len(validate_dataset)
    # Iterate over specified number of epochs
    for epoch in range(nepochs):
        ############
        # Training #
        ############
        model.train()
        # Initialise training loss
        train_loss = torch.Tensor([0.]).to(gpu)
        start_train = datetime.now()
        if root_rank:
            start_train_dataload = time()
        for i, (images, labels) in enumerate(train_loader):
            # Transfer training data to GPU
            images = images.to(gpu, non_blocking = True)
            labels = labels.to(gpu, non_blocking = True)
            if root_rank:
                stop_train_dataload = time()
            if root_rank:
                start_training = time()
            
            # Forward pass
            predictions = model(images)
            loss = loss_fn(predictions, labels)

            # Backward and optimisation
            opt.zero_grad()
            loss.backward()
            opt.step()

            # Update training loss
            train_loss += loss.item()

            if root_rank:
                stop_training = time()
            # Print training statistics at regular intervals (every 50 training steps per epoch)
            #if (i + 1) % 50 == 0 and root_rank:
            if root_rank:
                print('TRAINING: Epoch [{}/{}], Step [{}/{}], Loss: {:.4f}, Time data load: {:.3f}ms, Time training: {:.3f}ms'.format(
                    epoch + 1, nepochs, i + 1, total_train_step, loss.item(), (stop_train_dataload - start_train_dataload) * 1000,
                    (stop_training - start_training) * 1000
                ))
        
        ##############
        # Validation #
        ##############
        model.eval()
        val_loss = torch.Tensor([0.]).to(gpu)
        start_val = datetime.now()
        correct = 0
        total = 0
        if root_rank:
            start_val_dataload = time()
        # Track correct predictions in validation dataset for recording accuracy
        for j, (images, labels) in enumerate(validate_loader):
            images = images.to(gpu, non_blocking = True)
            labels = labels.to(gpu, non_blocking = True)
            if root_rank:
                stop_val_dataload = time()
            if root_rank:
                start_validation = time()

            # Don't compute gradients in validation phase
            with torch.no_grad():
                # Forward pass
                predictions = model(images)
                loss = loss_fn(predictions, labels)
            
            # Weight and cumulate the loss per GPU
            # Use images.size(0) instead of batch_size since last batch may be smaller
            val_loss += loss * images.size(0) / N
            predicted_labels = [list(l).index(max(l)) for l in predictions]
            epoch_correct = sum([float(predicted_labels[i] == labels[i]) for i in range(len(labels))])
            epoch_acc = epoch_correct / len(predictions)
            correct += epoch_correct
            total += len(predictions)
            
            if root_rank:
                stop_validation = time()
            # Print validation statistics every 50 steps each epoch
            #if ((j + 1) % 10 == 0) and (root_rank):
            if root_rank:
                print('VALIDATION: Epoch [{}/{}], Step [{}/{}], Loss: {:.4f}, Accuracy: {:.4f}, Time data load: {:.3f}ms, Time validation: {:.3f}ms'.format(
                        epoch + 1, nepochs, j + 1, total_val_step, val_loss.item(), epoch_acc, (stop_val_dataload - start_val_dataload) * 1000,
                        (stop_validation - start_validation) * 1000
                    ))
        
        # Sum weighted averages over all GPUs
        dist.all_reduce(val_loss, op = dist.ReduceOp.SUM)
        # Get accuracy of validation phase
        accuracy = correct / total

        # Print findal loss values for each phase
        if root_rank:
            print('Epoch [{}/{}], Training Loss: {:.4f}, Validation Loss: {:.4f}, Validation Accuracy: {:.4f}'.format(
                epoch + 1, nepochs, train_loss.item() / len(train_loader), val_loss.item(), accuracy# / len(val_loader)
            ))
    
    # Print total time taken
    if root_rank:
        print('Model training + validation complete in: ' + str(datetime.now() - start))
    
    # Cleanup
    dist.destroy_process_group()



def main():

    batch_size, nepochs = parse_args()

    # Sanity check for GPUs
    ngpus = torch.cuda.device_count()
    assert ngpus >= 2, f"Requires at least 2 GPUs to run, but got {ngpus}"

    training_dataset, validation_dataset = get_data()

    train_and_validate(nepochs, batch_size, training_dataset, validation_dataset)

    


if __name__ == "__main__":
    main()

