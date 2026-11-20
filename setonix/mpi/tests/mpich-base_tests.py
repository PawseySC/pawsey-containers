import reframe as rfm
import reframe.utility.sanity as sn
import os
from pathlib import Path
from reframe.core.backends import getlauncher


class GetContainerImage(rfm.RunOnlyRegressionTest):
    """
    Fixture for obtaining and defining full absolute
    path to container image used for testing. The mode
    parameter determines what type of testing being done
        image_testing:      Testing an image still in development
                            that is only local and not yet pushed to quay
        framework_testing:  Testing the framework with an established
                            reliable image already pushed to quay
    """
    mode = parameter(['image_testing', 'framework_testing'])
    image_name = parameter(['mpich-base_mpich4.2.2-ubuntu24.04'])

    # Used to help resolve path when testing local image
    script_dir = Path(__file__).resolve().parent

    @run_after('setup')
    def set_test_resources(self):
        # container pulls can require a lot of memory, depending on container
        # so even though it is just one task, reserve the whole node to be safe
        self.num_tasks = 1
        self.num_tasks_per_node = 1
        self.num_cpus_per_task = 128
        self.exclusive_access = True
        self.time_limit = '10m'
        
    @run_after('setup')
    def get_image(self):
        # Don't run the container pull via srun
        self.job.launcher = getlauncher('local')()

        # Point test to locally stored container image
        if self.mode == 'image_testing':
            self.container_dir = str((self.script_dir / '../artifacts/singularityImages'))
            # Nothing required to execute, but reframe requires executable to be set
            self.executable = ''
        # Pull container from quay.io into this test's stage directory
        elif self.mode == 'framework_testing':
            quay_path = f"docker://quay.io/pawsey/{self.image_name.replace('_', ':')}"
            self.modules = ['singularity/4.3.5-mpi']
            self.executable = 'singularity'
            self.executable_opts += f'pull --disable-cache {self.image_name + ".sif"} {quay_path}'.split()
            self.container_dir = self.stagedir
        
        self.image_path = os.path.join(self.container_dir, self.image_name + '.sif')

    @sanity_function
    def assert_image_exists(self):
        return sn.assert_true(os.path.exists(self.image_path))

# Base test with logic common to all mpich-base tests
class MpichBaseContainerTest(rfm.RunOnlyRegressionTest):
    """
    Base test class for mpich-base container image tests
    This contains all parameters, variables, etc. that are
    common to all tests
    """
    # Test parameters
    num_nodes = parameter([1, 2])

    # Metadata
    descr = 'Base test for mpich-base container MPI testing'
    maintiners = ['Craig Meyer']

    # Valid systems and PEs
    valid_systems = ['setonix:work', 'joey:work']
    valid_prog_environs = ['PrgEnv-gnu']

    # Modules to load
    modules = ['singularity/4.3.5-mpi']

    # The fixture 
    container_image = fixture(GetContainerImage, scope = 'session')

    @run_after('setup')
    def setup_env(self):
        self.env_vars = {
            'SINGULARITY_IMAGE': self.container_image.image_path,
            'MPICH_ENV_DISPLAY': '1',
            'MPICH_MEMORY_REPORT': '1',
            'MPICH_OFI_VERBOSE': '1',
            'OMP_NUM_THREADS': '1',
        }
    

# Test for OSU MPI benchmarks
@rfm.simple_test
class MpichBaseOSUTest(MpichBaseContainerTest):
    """
    Test running OSU benchmarks in mpich-base container
    """
    # Metadata
    descr = 'mpich-base container OSU MPI benchmark test'

    # Execution - run osu_latency as the first test
    binary = 'osu_latency'
    executable = 'singularity'
    executable_opts = f'exec $SINGULARITY_IMAGE {binary}'.split(' ')

    # Performance reference
    # NOTE: These are conservative numbers since primary purpose of test is functionality
    #       Performance should always fall in these bounds unless there is a sharp decline (30% or more)
    reference = {
        '*': {
            'OSU Latency': (60, None, 0.2, 'us'),
            'OSU Bandwidth': (50000, None, 0.2, 'us'),
            'OSU Allreduce': (1000, None, 0.2, 'us'),
        }
    }

    @run_after('setup')
    def set_test_resources(self):
        self.num_tasks_per_node = 1 + (self.num_nodes % 2)
        self.num_tasks = self.num_tasks_per_node * self.num_nodes
        self.num_cpus_per_task = 1
        self.time_limit = '15m'

    @run_before('run')
    def linkage_stage(self):
        self.prerun_cmds += [
            'echo "=== Linkage check ==="',
            f'{self.executable} exec $SINGULARITY_IMAGE bash -lc "'
            f'ldd \\\"\$(command -v osu_latency)\\\" | grep -E \'mpi|fabric|cxi|pmi|pmix|pals|xpmem\' || true"',
            'echo',
        ]
    @run_before('run')
    def binaries_stage(self):
        self.prerun_cmds += [
            'echo "=== OSU binaries check ==="',
            f'{self.executable} exec $SINGULARITY_IMAGE bash -lc "'
            'command -v osu_latency\n'
            'command -v osu_bw\n'
            'command -v osu_allreduce"',
            'echo',
            'echo "=== Runtime check ==="',
        ]
    @run_before('run')
    def run_osu_benchmarks(self):
        binaries = ['osu_bw', 'osu_allreduce']
        self.job.num_tasks = self.num_tasks
        self.job.num_tasks_per_node = self.num_tasks_per_node
        for bin in binaries:
            self.postrun_cmds += [
                f'{self.job.launcher.run_command(self.job)} {self.executable} exec $SINGULARITY_IMAGE {bin}'
            ]

    @sanity_function
    def assert_success(self):
        binaries_condition = sn.assert_eq(sn.count(sn.extractall('/usr/local/libexec/osu-micro-benchmarks/mpi', self.stdout)), 3)
        linkage_condition = sn.all([
            sn.assert_found('/opt/cray/pe/mpich', self.stdout),
            sn.assert_found('/opt/cray/libfabric', self.stdout),
        ])
        runtime_condition = sn.all([
            sn.assert_found('# OSU MPI Latency Test', self.stdout),
            sn.assert_found('# OSU MPI Bandwidth Test', self.stdout),
            sn.assert_found('# OSU MPI Allreduce Latency Test', self.stdout),
            sn.assert_eq(sn.count(sn.extractall('4194304', self.stdout)), 2),
            sn.assert_eq(sn.count(sn.extractall('1048576', self.stdout)), 3),
        ])
        return sn.all([
            binaries_condition,
            linkage_condition,
            runtime_condition
        ])


    @run_before('performance')
    def set_perf_vars(self):
        self.perf_variables = {
            'OSU Latency': self.extract_time(),
            'OSU Bandwidth': self.extract_time(benchmark = 'Bandwidth'),
            'OSU Allreduce': self.extract_time(benchmark = 'Allreduce'),
        }
    @performance_function('us')
    def extract_time(self, benchmark = 'Latency'):
        times = sn.evaluate(sn.findall(rf'1048576\s+([0-9]+.[0-9]+)', self.stdout))
        if benchmark == 'Latency':
            return float(times[0].groups(0)[0])
        elif benchmark == 'Bandwidth':
            return float(times[1].groups(0)[0])
        elif benchmark == 'Allreduce':
            return float(times[2].groups(0)[0])


# Test to check MPI communication using profile_util library
@rfm.simple_test
class MpichBaseMPICommTest(MpichBaseContainerTest):
    """
    Test running several MPI communication patterns in mpich-base container
    """
    # Metadata
    descr = 'mpich-base container MPI comms test'

    # Execution - run osu_latency as the first test
    binary = '/opt/profile_util/build/src/tests/test_mpi_comm'
    binary_opts = '-s 0.01 -i 1 -D 0 -C 0 -G 0 -S 0 -R 1 -B 1 -P 1 -p 1 -M 0'
    executable = 'singularity'
    executable_opts = f'exec $SINGULARITY_IMAGE {binary} {binary_opts}'.split(' ')

    # Performance reference
    # NOTE: These are conservative numbers since primary purpose of test is functionality
    #       Performance should always fall in these bounds unless there is a sharp decline (30% or more)
    reference = {
        '*': {
            'Allreduce': (1e7, None, 0.2, 'us'),
            'Bcast': (1e7, None, 0.2, 'us'),
            'SendRecv': (1e8, None, 0.2, 'us'),
        }
    }

    @run_after('setup')
    def set_test_resources(self):
        self.num_tasks_per_node = 8
        self.num_tasks = self.num_tasks_per_node * self.num_nodes
        self.num_cpus_per_task = 1
        self.time_limit = '15m'

    @run_before('run')
    def linkage_stage(self):
        self.prerun_cmds += [
            'echo "=== Linkage check ==="',
            f'{self.executable} exec $SINGULARITY_IMAGE '
            f"ldd {self.binary} | grep -E 'profile_util|mpi|fabric|cxi|pmi|pmix|pals|xpmem' || true"
            'echo', 'echo',
            'echo "=== Runtime check ==="',
        ]
    @run_before('run')
    def binaries_stage(self):
        self.prerun_cmds += [
            'echo "=== Binary availability check ==="',
            f'{self.executable} exec $SINGULARITY_IMAGE test -x {self.binary} && echo "{self.binary} exists!"',
            'echo',
        ]

    @sanity_function
    def assert_success(self):
        binaries_condition = sn.assert_found(f'{self.binary} exists!', self.stdout)
        linkage_condition = sn.all([
            sn.assert_found('libprofile_util', self.stdout),
            sn.assert_found('/opt/cray/pe/mpich', self.stdout),
            sn.assert_found('/opt/cray/libfabric', self.stdout),
        ])
        runtime_condition = sn.assert_found('Ending job', self.stdout),
        return sn.all([
            binaries_condition,
            linkage_condition,
            runtime_condition
        ])

    @run_before('performance')
    def set_perf_vars(self):
        self.perf_variables = {
            'AllReduce': self.extract_avg_time(),
            'Bcast': self.extract_avg_time(func = 'Bcast'),
            'SendRecv': self.extract_avg_time(func = 'SendRecv'),
        }
    @performance_function('us')
    def extract_avg_time(self, func = 'AllReduce'):
        times = sn.evaluate(sn.findall(rf'@MPIReportTimeStats.*@MPITest{func}.*timing.*max\]=\[([-+]?\d*\.?\d+(?:[eE][-+]?\d+)?)', self.stdout))
        ntimes = len(times)
        return sum([float(t.groups()[0]) for t in times]) / ntimes


# Test of MPI I/O
@rfm.simple_test
class MpichBaseMPIIOTest(MpichBaseContainerTest):
    """
    Test running MPI I/O in mpich-base container
    """
    # Test parameters
    num_files = parameter([10])
    file_size = parameter([1e8])

    # Metadata
    descr = 'mpich-base container MPI I/O test'

    # Performance reference
    # NOTE: These are conservative numbers since primary purpose of test is functionality
    #       Performance should always fall in these bounds unless there is a sharp decline (30% or more)
    reference = {
        '*': {
            'collective_write_avg': (500, -0.2, None, 'MB/s'),
            'non-collective_write_avg': (1000, -0.2, None, 'MB/s'),
            'collective_read_avg': (500, -0.2, None, 'MB/s'),
            'non-collective_read_avg': (1000, -0.2, None, 'MB/s'),
        }      
    }

    @run_after('setup')
    def set_source_dir(self):
        script_dir = self.container_image.script_dir
        self.sourcesdir = str((script_dir / 'fixtures').resolve())
    @run_after('setup')
    def setup_execution(self):
        self.sourcepath = 'mpi_io.cpp'
        self.binary = './mpi_io.exe'
        self.executable = 'singularity'
        self.executable_opts = f'exec $SINGULARITY_IMAGE {self.binary} {self.num_files} {self.file_size} $(pwd)'.split(' ')
    @run_after('setup')
    def set_test_resources(self):
        self.num_tasks_per_node = 4
        self.num_tasks = self.num_tasks_per_node * self.num_nodes
        self.num_cpus_per_task = 1
        self.time_limit = '10m'

    @run_before('run')
    def compilation_stage(self):
        self.prerun_cmds += [
            'echo "=== Compilation check ==="',
            f'{self.executable} exec $SINGULARITY_IMAGE '
            f'mpic++ -O2 {self.sourcepath} -o {self.binary} && echo "Compilation successful!"',
            'echo',
        ]
    @run_before('run')
    def linkage_stage(self):
        self.prerun_cmds += [
            'echo "=== Linkage check ==="',
            f'{self.executable} exec $SINGULARITY_IMAGE '
            f"ldd {self.binary} | grep -E 'mpi|fabric|cxi|pmi|pmix|pals|xpmem' || true ",
            'echo',
            'echo "=== Runtime check ==="',
        ]

    @sanity_function
    def assert_success(self):
        compilation_condition = sn.all([
            sn.assert_true(os.path.exists(self.binary)),
            sn.assert_found('Compilation successful!', self.stdout),
        ])
        linkage_condition = sn.all([
            sn.assert_found('/opt/cray/pe/mpich', self.stdout),
            sn.assert_found('/opt/cray/libfabric', self.stdout),
        ])
        runtime_condition = sn.all([
            sn.assert_found('MPI_CONTAINER_IO_SUCCESS', self.stdout),
            sn.assert_eq(sn.count(sn.extractall('Completed collective read from', self.stdout)), self.num_files),
            sn.assert_eq(sn.count(sn.extractall('Completed non-collective read from', self.stdout)), self.num_files),
            sn.assert_eq(sn.count(sn.extractall('Completed collective write to', self.stdout)), self.num_files),
            sn.assert_eq(sn.count(sn.extractall('Completed non-collective write to', self.stdout)), self.num_files),
        ])
        return sn.all([
            compilation_condition,
            linkage_condition,
            runtime_condition
        ])

    @run_before('performance')
    def set_perf_vars(self):
        self.perf_variables = {
            'collective_write_avg': self.extract_mpi_bandwidth(),
            'non-collective_write_avg': self.extract_mpi_bandwidth(mode = 'non-collective write'),
            'collective_read_avg': self.extract_mpi_bandwidth(mode = 'collective read'),
            'non-collective_read_avg': self.extract_mpi_bandwidth(mode = 'non-collective read'),
        }
    @performance_function('MB/s')
    def extract_mpi_bandwidth(self, mode = 'collective write', kind = 'average'):
        bw = sn.evaluate(sn.findall(rf'.*\s{mode}.*bandwidth ([0-9]+.[0-9]+) MB\/s', self.stdout))
        nfiles = len(bw)
        return sum([float(x.groups()[0]) for x in bw]) / nfiles


# Test of mpi4py
@rfm.simple_test
class MpichBaseMPI4pyTest(MpichBaseContainerTest):
    """
    Test running mpi4py in mpich-base container image
    """

    # Metadata
    desc = 'mpich-base container mpi4py test'

    # Execution
    python_script = 'mpi4py_acceptance.py'
    executable = 'singularity'
    executable_opts = f'exec $SINGULARITY_IMAGE python3 {python_script}'.split(' ')

    @run_after('setup')
    def set_source_dir(self):
        script_dir = self.container_image.script_dir
        self.sourcesdir = str((script_dir / 'fixtures').resolve())
    @run_after('setup')
    def set_test_resources(self):
        self.num_tasks_per_node = 4
        self.num_tasks = self.num_tasks_per_node * self.num_nodes
        self.num_cpus_per_task = 1
        self.time_limit = '15m'

    @run_before('run')
    def linkage_stage(self):
        self.prerun_cmds += [
            'echo "=== Linkage check ==="',
            f'{self.executable} exec $SINGULARITY_IMAGE bash -lc "'
            'MPI_SO=\$(python3 -c \'import mpi4py.MPI as m; print(m.__file__)\'); echo \\\"MPI_SO=\${MPI_SO}\\\"; ldd \\\"\${MPI_SO}\\\" | grep -E \'mpi|fabric|cxi|pmi|pmix|pals|xpmem\' || true"',
            'echo',
            'echo "=== Runtime check ==="',
        ]

    @sanity_function
    def assert_success(self):
        linkage_condition = sn.all([
            sn.assert_found('/opt/cray/pe/mpich', self.stdout),
            sn.assert_found('/opt/cray/libfabric', self.stdout),
        ])
        runtime_condition = sn.assert_found(f'MPI4PY_ACCEPTANCE_SUCCESS size={self.num_tasks}', self.stdout)
        return sn.all([
            linkage_condition,
            runtime_condition
        ])