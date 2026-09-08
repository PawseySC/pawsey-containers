import reframe as rfm
import reframe.utility.sanity as sn
import os
from pathlib import Path

# Base test with logic common to all mpich-base tests
class MpichBaseContainerTest(rfm.RunOnlyRegressionTest):
    def __init__(self, name, **kwargs):

        # Metadata
        self.descr = 'Base test for mpich-base container MPI testing'
        self.maintiners = ['Craig Meyer']

        # Valid systems and PEs
        self.valid_systems = ['setonix:work', 'joey:work']
        self.valid_prog_environs = ['PrgEnv-gnu']

        # Modules to load
        self.modules = ['singularity/4.1.0-mpi']

        # Environment variables
        script_dir = Path(__file__).resolve().parent
        container_dir = str((script_dir / '../artifacts/singularityImages'))
        self.env_vars = {
            'SINGULARITY_IMAGE': os.path.join(container_dir, f'{self.image_name}.sif'),
            'MPICH_ENV_DISPLAY': '1',
            'MPICH_MEMORY_REPORT': '1',
            'MPICH_OFI_VERBOSE': '1',
            'OMP_NUM_THREADS': '1',
        }
    
    # Test parameters
    image_name = parameter(['mpich-base--mpich4.2.2-ubuntu24.04'])
    num_nodes = parameter([1, 2])


# Test for OSU MPI benchmarks
@rfm.simple_test
class MpichBaseOSUTest(MpichBaseContainerTest):
    def __init__(self, **kwargs):
        super().__init__('RocmMpichBaseOSUTest', **kwargs)

        # Metadata
        self.descr = 'mpich-base container OSU MPI benchmark test'

        # Job configuration
        self.num_tasks_per_node = 1 + (self.num_nodes % 2)
        self.num_tasks = self.num_tasks_per_node * self.num_nodes
        self.time_limit = '15m'

        # Execution - run osu_latency as the first test
        binary = 'osu_latency'
        self.executable = 'singularity'
        self.executable_opts = f'exec $SINGULARITY_IMAGE {binary}'.split(' ')

        self.perf_variables = {
            'OSU Latency': self.extract_time(),
            'OSU Bandwidth': self.extract_time(benchmark = 'Bandwidth'),
            'OSU Allreduce': self.extract_time(benchmark = 'Allreduce'),
        }
        # NOTE: These are conservative numbers since primary purpose of test is functionality
        #       Performance should always fall in these bounds unless there is a sharp decline (30% or more)
        self.reference = {
            '*': {
                'OSU Latency': (30 * self.num_nodes, None, 0.2, 'us'),
                'OSU Bandwidth': (50000, None, 0.2, 'us'),
                'OSU Allreduce': (450, None, 0.2, 'us'),
            }
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

    # Run two more OSU benchmarks to cover a wide range
    @run_before('run')
    def run_osu_benchmarks(self):
        binaries = ['osu_bw', 'osu_allreduce']
        self.job.num_tasks = self.num_tasks
        self.job.num_tasks_per_node = self.num_tasks_per_node
        for bin in binaries:
            self.postrun_cmds += [
                f'{self.job.launcher.run_command(self.job)} {self.executable} exec $SINGULARITY_IMAGE {bin}'
            ]
    # Binary existence check
    @run_before('run')
    def binaries_stage(self):
        self.prerun_cmds += [
            'echo "=== OSU binaries check ==="',
            f'{self.executable} exec $SINGULARITY_IMAGE bash -lc "'
            'command -v osu_latency\n'
            'command -v osu_bw\n'
            'command -v osu_allreduce"'
        ]
    # Check link against libfabric, mpich, etc.
    @run_before('run')
    def linkage_stage(self):
        self.prerun_cmds += [
            'echo "=== Linkage check ==="',
            f'{self.executable} exec $SINGULARITY_IMAGE bash -lc "'
            f'ldd \\\"\$(command -v osu_latency)\\\" | grep -E \'mpi|fabric|cxi|pmi|pmix|pals|xpmem\' || true"',
            'echo',
            'echo "=== Runtime check ==="',
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


# Test to check MPI communication using profile_util library
@rfm.simple_test
class MpichBaseMPICommTest(MpichBaseContainerTest):
    def __init__(self, **kwargs):
        super().__init__('MpichBaseMPICommTest', **kwargs)

        # Metadata
        self.descr = 'mpich-base container MPI comms test'

        # Job configuration
        self.num_tasks_per_node = 8
        self.num_tasks = self.num_tasks_per_node * self.num_nodes
        self.time_limit = '15m'

        # Execution - run osu_latency as the first test
        self.binary = '/opt/profile_util/build/src/tests/test_mpi_comm'
        binary_opts = '-s 0.01 -i 1 -D 0 -C 0 -G 0 -S 0 -R 1 -B 1 -P 1 -p 1 -M 0'
        self.executable = 'singularity'
        self.executable_opts = f'exec $SINGULARITY_IMAGE {self.binary} {binary_opts}'.split(' ')

        self.perf_variables = {
            'AllReduce': self.extract_avg_time(),
            'Bcast': self.extract_avg_time(func = 'Bcast'),
            'SendRecv': self.extract_avg_time(func = 'SendRecv'),
        }
        # NOTE: These are conservative numbers since primary purpose of test is functionality
        #       Performance should always fall in these bounds unless there is a sharp decline (30% or more)
        self.reference = {
            '*': {
                'Allreduce': (1e7, None, 0.2, 'us'),
                'Bcast': (1e7, None, 0.2, 'us'),
                'SendRecv': (1e8, None, 0.2, 'us'),
            }
        }

    @performance_function('us')
    def extract_avg_time(self, func = 'AllReduce'):
        times = sn.evaluate(sn.findall(rf'@MPIReportTimeStats.*@MPITest{func}.*timing.*max\]=\[([-+]?\d*\.?\d+(?:[eE][-+]?\d+)?)', self.stdout))
        ntimes = len(times)
        return sum([float(t.groups()[0]) for t in times]) / ntimes

    @run_before('run')
    def binaries_stage(self):
        self.prerun_cmds += [
            'echo "=== Binary availability check ==="',
            f'{self.executable} exec $SINGULARITY_IMAGE test -x {self.binary} && echo "{self.binary} exists!"',
            'echo',
        ]
    @run_before('run')
    def linkage_stage(self):
        self.prerun_cmds += [
            'echo "=== Linkage check ==="',
            f'{self.executable} exec $SINGULARITY_IMAGE '
            f"ldd {self.binary} | grep -E 'profile_util|mpi|fabric|cxi|pmi|pmix|pals|xpmem' || true"
            'echo',
            'echo',
            'echo "=== Runtime check ==="',
        ]

    @sanity_function
    def assert_success(self):
        binaries_condition = sn.assert_found(f'{self.binary} exists!', self.stdout)
        linkage_condition = sn.all([
            sn.assert_found('libprofile_util', self.stdout),
            sn.assert_found('/opt/cray/pe/mpich', self.stdout),
            sn.assert_found('/opt/cray/libfabric', self.stdout),
        ])
        runtime_condition = sn.all([
            sn.assert_found('Ending job', self.stdout),
        ])

        return sn.all([
            binaries_condition,
            linkage_condition,
            runtime_condition
        ])

# Test of MPI I/O
@rfm.simple_test
class MpichBaseMPIIOTest(MpichBaseContainerTest):
    def __init__(self, **kwargs):
        super().__init__('MpichBaseMPIIOTest', **kwargs)

        # Metadata
        self.descr = 'mpich-base container MPI I/O test'

        # Job configuration
        self.num_tasks_per_node = 4
        self.num_tasks = self.num_tasks_per_node * self.num_nodes
        self.time_limit = '10m'

        script_dir = Path(__file__).resolve().parent
        self.sourcesdir = str((script_dir / 'fixtures').resolve())
        # Execution
        self.sourcepath = 'mpi_io.cpp'
        self.binary = './mpi_io.exe'
        self.executable = 'singularity'
        self.executable_opts = f'exec $SINGULARITY_IMAGE {self.binary} {self.num_files} {self.file_size} $(pwd)'.split(' ')
        self.keep_files = ['*collective']

        self.perf_variables = {
            'collective_write_avg': self.extract_mpi_bandwidth(),
            'non-collective_write_avg': self.extract_mpi_bandwidth(mode = 'non-collective write'),
            'collective_read_avg': self.extract_mpi_bandwidth(mode = 'collective read'),
            'non-collective_read_avg': self.extract_mpi_bandwidth(mode = 'non-collective read'),
        }
        # NOTE: These are conservative numbers since primary purpose of test is functionality
        #       Performance should always fall in these bounds unless there is a sharp decline (30% or more)
        self.reference = {
            '*': {
                'collective_write_avg': (500, -0.2, None, 'MB/s'),
                'non-collective_write_avg': (1000, -0.2, None, 'MB/s'),
                'collective_read_avg': (500, -0.2, None, 'MB/s'),
                'non-collective_read_avg': (1000, -0.2, None, 'MB/s'),
            }
                      
        }
    
    # Test parameters
    num_files = parameter([10])
    file_size = parameter([1e8])

    @performance_function('MB/s')
    def extract_mpi_bandwidth(self, mode = 'collective write', kind = 'average'):
        bw = sn.evaluate(sn.findall(rf'.*\s{mode}.*bandwidth ([0-9]+.[0-9]+) MB\/s', self.stdout))
        nfiles = len(bw)

        return sum([float(x.groups()[0]) for x in bw]) / nfiles

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

# Test of mpi4py
@rfm.simple_test
class MpichBaseMPI4pyTest(MpichBaseContainerTest):
    def __init__(self, **kwargs):
        super().__init__('MpichBaseMPI4pyTest', **kwargs)

        # Metadata
        self.descr = 'mpich-base container mpi4py test'

        # Job configuration
        self.num_tasks_per_node = 4
        self.num_tasks = self.num_tasks_per_node * self.num_nodes
        self.time_limit = '15m'

        script_dir = Path(__file__).resolve().parent
        self.sourcesdir = str((script_dir / 'fixtures').resolve())
        # Execution
        self.python_script = 'mpi4py_acceptance.py'
        self.executable = 'singularity'
        self.executable_opts = f'exec $SINGULARITY_IMAGE python3 {self.python_script}'.split(' ')


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