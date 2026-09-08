import reframe as rfm
import reframe.utility.sanity as sn
import os
from pathlib import Path

# Test of MPI I/O
@rfm.simple_test
class LustreMpichBaseMPIIOTest(rfm.RunOnlyRegressionTest):
    def __init__(self):

        # Metadata
        self.descr = 'lustre-mpich-base container MPI I/O test'
        self.maintiners = ['Craig Meyer']

        # Valid systems and PEs
        self.valid_systems = ['setonix:work', 'joey:work']
        self.valid_prog_environs = ['PrgEnv-gnu']

        # Job configuration
        self.num_tasks_per_node = 4
        self.num_tasks = self.num_tasks_per_node * self.num_nodes
        self.time_limit = '10m'

        # Modules to load
        self.modules = ['singularity/4.1.0-mpi']

        # Environment variables
        script_dir = Path(__file__).resolve().parent
        container_dir = str((script_dir / '../artifacts/singularityImages'))
        self.env_vars = {
            'SINGULARITY_IMAGE': os.path.join(container_dir, f'mpich-lustre-base--mpich{self.mpich_version}-lustrerelease-ubuntu{self.ubuntu_version}.sif'),
            'MPICH_ENV_DISPLAY': '1',
            'MPICH_MEMORY_REPORT': '1',
            'MPICH_OFI_VERBOSE': '1',
            'OMP_NUM_THREADS': '1',
        }

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
    mpich_version = parameter(['4.2.2'])
    ubuntu_version = parameter(['24.04'])
    num_nodes = parameter([1, 2])
    num_files = parameter([10])
    file_size = parameter([1e8]) # 100MB file size

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
    def linkage_state(self):
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


