import tensorflow as tf
import numpy as np
import os
import certifi

os.environ["SSL_CERT_FILE"] = certifi.where()
os.environ["REQUESTS_CA_BUNDLE"] = certifi.where()
# Enable memory growth on GPUs
gpus = tf.config.list_physical_devices("GPU")
for gpu in gpus:
    tf.config.experimental.set_memory_growth(gpu, True)

# Distribution strategy
strategy = tf.distribute.MirroredStrategy()
num_replicas = strategy.num_replicas_in_sync
print(f"Number of devices: {num_replicas}")

# Parameters
batch_size_per_replica = 128  # can adjust for performance
global_batch_size = batch_size_per_replica * num_replicas
num_epochs = 10

# Load MNIST
(train_images, train_labels), (val_images, val_labels) = tf.keras.datasets.mnist.load_data()

# Normalize and expand dims for Conv2D
train_images = train_images.astype(np.float32) / 255.0
val_images = val_images.astype(np.float32) / 255.0
train_images = np.expand_dims(train_images, axis=-1)
val_images = np.expand_dims(val_images, axis=-1)

# Trim training set size to multiple of global batch size
train_remainder = train_images.shape[0] % global_batch_size
if train_remainder != 0:
    print(f"Trimming {train_remainder} training samples for batch size alignment.")
    train_images = train_images[:-train_remainder]
    train_labels = train_labels[:-train_remainder]

# Trim validation set size similarly
val_remainder = val_images.shape[0] % global_batch_size
if val_remainder != 0:
    print(f"Trimming {val_remainder} validation samples for batch size alignment.")
    val_images = val_images[:-val_remainder]
    val_labels = val_labels[:-val_remainder]

# Create tf.data datasets for safe distributed batching
train_dataset = tf.data.Dataset.from_tensor_slices((train_images, train_labels))
train_dataset = train_dataset.shuffle(10000).repeat().batch(global_batch_size).prefetch(tf.data.AUTOTUNE)

val_dataset = tf.data.Dataset.from_tensor_slices((val_images, val_labels))
val_dataset = val_dataset.batch(global_batch_size).prefetch(tf.data.AUTOTUNE)

# Build model function inside strategy scope
def build_model():
    model = tf.keras.Sequential([
        tf.keras.layers.Conv2D(32, (3,3), activation = 'relu', input_shape = (28, 28, 1)),
        tf.keras.layers.Conv2D(64, (3,3), activation = 'relu'),
        tf.keras.layers.MaxPooling2D(pool_size = (2, 2)),
        tf.keras.layers.Dropout(0.25),
        tf.keras.layers.Flatten(),
        tf.keras.layers.Dense(128, activation = 'relu'),
        tf.keras.layers.Dropout(0.5),
        tf.keras.layers.Dense(10, activation = 'softmax')
    ])
    model.compile(
        loss = 'sparse_categorical_crossentropy',
        optimizer = 'adam',
        metrics = ['accuracy']
    )
    return model

with strategy.scope():
    model = build_model()

steps_per_epoch = train_images.shape[0] // global_batch_size
validation_steps = val_images.shape[0] // global_batch_size

print(f"Training samples: {train_images.shape[0]}")
print(f"Validation samples: {val_images.shape[0]}")
print(f"Global batch size: {global_batch_size}")
print(f"Steps per epoch: {steps_per_epoch}, Validation steps: {validation_steps}")

history = model.fit(
    train_dataset,
    epochs = num_epochs,
    steps_per_epoch = steps_per_epoch,
    validation_data = val_dataset,
    validation_steps = validation_steps,
)

print('Model finished training and validation')

# Clear session and garbage collect to avoid fragmentation in next run
tf.keras.backend.clear_session()
