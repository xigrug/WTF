#!/bin/ksh

## testWrf.ksh
##
##  Builds a test directory for a particular namelist file and WRF build, then runs both 
##  "real" and "wrf" in that test directory.  
##
##  NOTE: unless -C is specified, tests will not be re-performed if a successful forecast already exists
##        in a test directory. 
##  
##  Author: Brian Bonnlander
##

if $DEBUG_WTF; then
   set -x
fi

# Include common functions
.  $WRF_TEST_ROOT/scripts/Common.ksh


usage(){
   echo >&2 "usage: $0 [-G BATCH_ACCOUNT] [-C] -d <test_dir> -t <wrf_root_dir> -m <regdata_dir> -n <namelist_path> -par <parallel_type> -wt <wrf_type> "
   echo >&2 ""
   echo >&2 "   (-G BATCH_ACCOUNT uses the given account number/string for mpi and openmp runs.)"
   echo >&2 "   (specifying -C will 'clobber' a test that may have been done in the past.)"
   echo >&2 "   (<parallel_type> is one of the strings in {serial, openmp, mpi}.)"
   echo >&2 "   (<wrf_type> is one of the strings in {em_real, em_hill2d_x, em_b_wave, em_quarter_ss, nmm_real, nmm_nest}.)"
}




##
## getTableNames():
##    Searches the top-level WRF Makefile to create a list of WRF tables for linking into the test directory.
##
getTableNames()
{
   wrfType=$1
   # grep in the Makefile for 'ln -s' commands, remove non-table names, split lines into individual commands.
   # for WRFDA and WRFLPLUS, we need the "DBL" tables
   if [[ $WRF_TYPE = "wrfda_3dvar" ]] || [[ $WRF_TYPE = "wrfda_4dvar" ]] || [[ $WRF_TYPE = "wrfplus" ]];then
      WRF_TABLES=`grep 'ln -s' ${WRF_ROOT_DIR}/Makefile | egrep -v '=|input|namelist|.exe' | tr ";" "\n" | grep 'ln -s' | awk '{print $3}' | sort -u`
   else
      WRF_TABLES=`grep 'ln -s' ${WRF_ROOT_DIR}/Makefile | egrep -v '=|input|DBL|namelist|.exe' | tr ";" "\n" | grep 'ln -s' | awk '{print $3}' | sort -u`
   fi
   TABLE_NAMES=''
   # Now isolate just the filenames from their parent directory pathnames. 
   for f in `echo $WRF_TABLES`; do
      name=`basename $f`
      echo $name
      TABLE_NAMES=`echo $TABLE_NAMES $name`
   done

   # Send names to stdout, where they can be captured by invoking function with `getTableNames`.
   echo $TABLE_NAMES
}




##
## Usage: jobString=`getJobString $wrfType $parallelType $namelistPath`
##
##  Returns a string identifier for this test to give to BSUB.
##
getJobString()
{
   wrfType=$1
   parallelType=$2
   nlFile=$3
   nlSuffix=`getFileSuffix $nlFile`

   case $wrfType in
        em_real)         part1='er'   ;;
        em_b_wave)       part1='eb'   ;;
        em_quarter_ss)   part1='eq'   ;;
        em_hill2d_x)     part1='eh'   ;;
        em_chem)         part1='ec'   ;;
        em_chem_kpp)     part1='ek'   ;;
        nmm_real)        part1='nr'   ;;
        nmm_nest)        part1='nn'   ;;
        nmm_hwrf)        part1='nh'   ;;
        wrfda_3dvar)     part1='3d'   ;;
        wrfplus)         part1='wp'   ;;
        wrfda_4dvar)     part1='4d'   ;;
        *)               echo "$0::getJobString: unknown wrfType '$wrfType'"
                         exit 2
   esac

   case $parallelType in
        serial)   part2='se'   ;;
        openmp)   part2='sm'   ;;
        mpi)      part2='dm'   ;;
        *)        echo "$0::getJobString: unknown parallelType '$parallelType'"
                  exit 2
   esac

   echo "t.${part1}.${part2}.${nlSuffix}"
}




##
##  Initialize command-line variables.  
##

testDir=''        #  The directory where the test will be run
WRF_ROOT_DIR=''   #  The directory where WRF run-time tables are located
REGDATA_PATH=''   #  The directory containing all regression data files for this test
NAMELIST_PATH=''  #  The path to the namelist file 
BATCH_ACCOUNT=''  #  The account number or string to use for a batch-submitted openmp or mpi test
PARALLEL_TYPE=''  #  Should be 'serial', 'openmp', or 'mpi' 
WRF_TYPE=''       #  Should be one of 'em_real', 'em_b_wave', 'nmm_real', etc.
CLOBBER=false     #  If true, pre-existing test results are potentially lost and test is run again.


##
## Parse command line and set variables. 
##

CURRENT_DIR=`pwd`

while [ $# -gt 0 ]
do
    case "$1" in
        -G)  shift;  BATCH_ACCOUNT=$1   ;;
        -d)  shift;  testDir=$1         ;;
        -t)  shift;  WRF_ROOT_DIR=$1    ;;
        -m)  shift;  REGDATA_PATH=$1    ;;
        -n)  shift;  NAMELIST_PATH=$1   ;;
        -par)shift;  PARALLEL_TYPE=$1   ;;
        -wt) shift;  WRF_TYPE=$1        ;;
        -C)          CLOBBER=true       ;;
        *)  usage
            exit 1
    esac
    shift
done


##
## Exit if any required parameter is not given.
##

if [[ -z $testDir ]]      || [[ -z $WRF_ROOT_DIR ]] ||
   [[ -z $REGDATA_PATH ]]  || [[ -z $NAMELIST_PATH ]] ||
   [[ -z $PARALLEL_TYPE ]]  || [[ -z $WRF_TYPE ]] || 
   [[ -z $BATCH_ACCOUNT ]]; then 
   usage
   exit 1
fi

##
## Verify existence of directories and files.  
##

OS_NAME=`uname`


# WRF root directory must exist, top-level Makefile must exist, test/em_real directory must exist.
if [[ ! -d $WRF_ROOT_DIR ]] || [[ ! -f $WRF_ROOT_DIR/Makefile ]] || [[ ! -d $WRF_ROOT_DIR/test/em_real ]]; then
   echo "WRF source root directory '${WRF_ROOT_DIR}' not found or missing files; exiting."
   exit 2
fi

# Namelist file must exist and have nonzero size. 
if [[ ! -e $NAMELIST_PATH ]] || [[ ! -s $NAMELIST_PATH ]]; then
   echo "Namelist file '${NAMELIST_PATH}' not found or has zero size; exiting."
   exit 2
fi

# Regression data directory must exist. 
REGDATA_FILES=''
if [[ ! -d $REGDATA_PATH ]]; then
   echo "Regression data directory does not exist; exiting: '${REGDATA_PATH}'"
   exit 2
fi

REGDATA_FILES=`ls ${REGDATA_PATH}/*`


# Set the number of processors/threads to use for the test.
if [ "$BATCH_COMPILE" = false -a "$BATCH_TEST" = false ]; then
   NUM_PROC=$NUM_PROC_TEST
else
   NUM_PROC=`grep NUM_PROCESSORS ${NAMELIST_PATH} | cut -d '=' -f 2`
   if [ -z "$NUM_PROC" ]; then
      NUM_PROC=$NUM_PROC_TEST
   fi
fi


if [[ $WRF_TYPE = "wrfda_3dvar" ]] || [[ $WRF_TYPE = "wrfda_4dvar" ]];then
   # Getting hacky here; for WRFDA, only one executable needs to be run, so we can use 
   # $REAL_COMMAND to replace some data files that need to be 8-bit for 4dvar and WRFPLUS
   case $PARALLEL_TYPE in
       serial) REAL_COMMAND="\mv RRTM_DATA_DBL RRTM_DATA"
               WRF_COMMAND="./da_wrfvar.exe > wrfda.out 2>&1 "
               NUM_PROC=1
               ;;
       mpi)    if $BATCH_TEST; then
                   case $BATCH_QUEUE_TYPE in
                        LSF) REAL_COMMAND="\mv RRTM_DATA_DBL RRTM_DATA"
                             WRF_COMMAND="mpirun.lsf ./da_wrfvar.exe "
                             ;;
                        NQS) REAL_COMMAND="\mv RRTM_DATA_DBL RRTM_DATA"
                             WRF_COMMAND="mpirun ./da_wrfvar.exe "
                             ;;
                   esac
               else
                   REAL_COMMAND="\mv RRTM_DATA_DBL RRTM_DATA"
                   WRF_COMMAND="mpirun -machinefile machfile -np $NUM_PROC_TEST ./da_wrfvar.exe "
               fi
               ;;
       *) echo "$0: Error, unknown parallel setting ${PARALLEL_TYPE}."
          exit 2
   esac

elif [[ $WRF_TYPE = "wrfplus" ]];then
   # For WRFPLUS, only run wrf.exe
   case $PARALLEL_TYPE in
       serial) REAL_COMMAND="\mv RRTM_DATA_DBL RRTM_DATA"
               WRF_COMMAND="./wrf.exe > wrfplus.out 2>&1 "
               NUM_PROC=1
               ;;
       mpi)    if $BATCH_TEST; then
                   case $BATCH_QUEUE_TYPE in
                        LSF) REAL_COMMAND="\mv RRTM_DATA_DBL RRTM_DATA"
                             WRF_COMMAND="mpirun.lsf ./wrf.exe "
                             ;;
                        NQS) REAL_COMMAND="\mv RRTM_DATA_DBL RRTM_DATA"
                             WRF_COMMAND="mpirun ./wrf.exe "
                             ;;
                   esac
               else
                   REAL_COMMAND="\mv RRTM_DATA_DBL RRTM_DATA"
                   WRF_COMMAND="mpirun -machinefile machfile -np $NUM_PROC_TEST ./wrf.exe "
               fi
               ;;
       *) echo "$0: Error, unknown parallel setting ${PARALLEL_TYPE}."
          exit 2
   esac

else
   # For WRF, Get the invocation strings for running prewrf.exe and wrf.exe.
   case $PARALLEL_TYPE in
       serial) REAL_COMMAND="./prewrf.exe > prewrf.out 2>&1 "
               WRF_COMMAND="./wrf.exe > wrf.out 2>&1 "
               NUM_PROC=1
               ;;
       openmp) REAL_COMMAND="./prewrf.exe > prewrf.out 2>&1 "
               WRF_COMMAND="./wrf.exe > wrf.out 2>&1 "
               export OMP_NUM_THREADS=$NUM_PROC_TEST
               ;;
       mpi)    if $BATCH_TEST; then
                   case $BATCH_QUEUE_TYPE in
                        LSF) REAL_COMMAND="mpirun.lsf ./prewrf.exe "
                             WRF_COMMAND="mpirun.lsf  ./wrf.exe "
           		  ;;
                        NQS) REAL_COMMAND="mpirun ./prewrf.exe "
                             WRF_COMMAND="mpirun ./wrf.exe "
           		  ;;
                   esac
               else
                   REAL_COMMAND="mpirun -machinefile machfile -np $NUM_PROC_TEST ./prewrf.exe "
                   WRF_COMMAND="mpirun -machinefile machfile -np $NUM_PROC_TEST ./wrf.exe " 
               fi
               ;;
       *) echo "$0: Error, unknown parallel setting ${PARALLEL_TYPE}."
          exit 2
   esac
fi



##
##  If test directory already exists, rename it so it has the current process ID appended to it.
##

CREATE_DIR=true
if [ -d $testDir ]; then
    if $CLOBBER; then
       newDir=${testDir}.$$
       echo "Moving existing directory '$testDir' to '$newDir'."
       mv $testDir $newDir
    else
       CREATE_DIR=false
       # If there are no failures reported from last run, skip test. 
       # Also, re-route error message about no files to /dev/null.
       fails=`ls $testDir/FAIL*.tst 2> /dev/null`
       if [ -z "$fails" -a -f $testDir/SUCCESS_FCST.tst ]; then
          echo TESTS SUCCESSFUL for $testDir... exiting early.  
          exit 0
       fi
    fi
fi



##
## Build and populate test directory; report any errors.
##

if $CREATE_DIR; then
    mkdir -p $testDir
    if [[ $? -ne 0 ]]; then
       echo "Unable to create test directory '${testDir}'; exiting test." 
       exit 2
    fi
    
    for f in $REGDATA_FILES; do
       fullpath=`makeFullPath $f $CURRENT_DIR`
       ln -sf $fullpath $testDir
       if [[ $? -ne 0 ]]; then
          echo "Unable to link regression data file $fullpath into '${testDir}'; exiting test." 
          exit 2
       fi
    done
    
    NAMELIST_PATH=`makeFullPath $NAMELIST_PATH $CURRENT_DIR`
    # Don't link namelist file, so user can experiment with settings in the working directory.
    #ln -sf $NAMELIST_PATH $testDir/namelist.input
    cp $NAMELIST_PATH $testDir/namelist.input
    if [[ $? -ne 0 ]]; then
       echo "Unable to copy namelist.input file into '${testDir}'; exiting test." 
       exit 2
    fi

    # Assume data tables exist in $WRF_ROOT_DIR/run for now; link them into the test directory.
    TBL_FILES=$(getTableNames WRF_TYPE)
    for f in $TBL_FILES; do
       fullPath=${WRF_ROOT_DIR}/run/$f 
       if [ ! -f $fullPath ]; then
          echo File does not exist; verify WRF top-level directory: $fullPath
          exit 2
       fi
       ln -sf $fullPath $testDir
    done

fi    


if [[ $WRF_TYPE = "wrfda_3dvar" ]] || [[ $WRF_TYPE = "wrfda_4dvar" ]];then
   # Link in the WRFDA executable if it exists.
   wrfdaFile=$WRF_ROOT_DIR/var/build/da_wrfvar.exe

   if [ -f $wrfdaFile ]; then
      ln -sf $wrfdaFile $testDir/da_wrfvar.exe
   else
      echo "WRFDA Compile failure: File does not exist: $wrfdaFile"
      touch $testDir/FAIL_COMPILE.tst
      exit 2
   fi
elif [[ $WRF_TYPE = "wrfplus" ]];then
   # Link in the WRFPLUS executable if it exists.
   wrfplusFile=$WRF_ROOT_DIR/main/wrf.exe

   if [ -f $wrfplusFile ]; then
      ln -sf $wrfplusFile $testDir/wrf.exe
   else
      echo "WRFPLUS Compile failure: File does not exist: $wrfplusFile"
      touch $testDir/FAIL_COMPILE.tst
      exit 2
   fi
else
   # Link in the preprocessor and WRF executables if they exist.
   realFile=$WRF_ROOT_DIR/main/prewrf_${WRF_TYPE}.exe
   wrfFile=$WRF_ROOT_DIR/main/wrf.exe


   if [ -f $realFile ]; then
      ln -sf $realFile $testDir/prewrf.exe
   else
      echo "Compile failure: File does not exist: $realFile"
      touch $testDir/FAIL_COMPILE.tst
      exit 2
   fi


   if [ -f $wrfFile ]; then
      ln -sf $wrfFile $testDir/wrf.exe
   else
      echo "Compile failure: File does not exist: $wrfFile"
      touch $testDir/FAIL_COMPILE.tst
      exit 2
   fi
fi

if [[ $WRF_TYPE = "wrfda_3dvar" ]] || [[ $WRF_TYPE = "wrfda_4dvar" ]];then
   # WRFDA only supports netCDF I/O
   ln -sf $WRF_ROOT_DIR/external/io_netcdf/diffwrf $testDir
elif [[ $WRF_TYPE = "wrfplus" ]];then
   ln -sf $WRF_ROOT_DIR/external/io_netcdf/diffwrf $testDir
else

   # Link in the utilities for checking WRF output; depends on the output format.
   outputForm=`grep io_form_history $testDir/namelist.input | cut -d '=' -f 2 | awk '{print $1;}'`
   case $outputForm in
       1) # Binary
          ln -sf $WRF_ROOT_DIR/external/io_int/diffwrf $testDir
          ;;
       2) # NetCDF
          ln -sf $WRF_ROOT_DIR/external/io_netcdf/diffwrf $testDir
          ;;
       5) # Grib1
          ln -sf $WRF_ROOT_DIR/external/io_grib1/wgrib.exe $testDir
          ln -sf $WRF_ROOT_DIR/external/io_grib1/diffwrf $testDir
          ;;
       *) echo "$0:  unknown WRF output format: $outputForm"
          exit 2
   esac

fi

# Create a script to actually run the test.
if $CREATE_DIR; then
    if [ "$PARALLEL_TYPE" = "mpi" ]; then    
        ##  Put all batched commands related to running the test in the local file "test.sh". 
        cat >| $testDir/test.sh << EOF
\rm -f rsl.out* rsl.err*
date >| testStart.txt
$REAL_COMMAND
mkdir -p rsl.PREWRF
\mv -f rsl.out* rsl.err* rsl.PREWRF
$WRF_COMMAND
date >| testEnd.txt
EOF
    
        ## Also add a machine file.   Do not indent the next few lines!
        HOSTNAME=`hostname`
        cat >| $testDir/machfile << EOF
$HOSTNAME
$HOSTNAME
$HOSTNAME
$HOSTNAME
EOF
    
    else
        ##  Put all non-batched commands related to running the test in the local file "test.sh".    
        ##  Do not indent the next few lines!
        cat >| $testDir/test.sh << EOF
   echo shell = $0
   date >| testStart.txt
   $REAL_COMMAND
   $WRF_COMMAND
   date >| testEnd.txt
EOF
    fi
fi  # if $CREATE_DIR


# To allow many tests to be done in parallel, put all tests (even serial jobs) in a processing queue.  
if $BATCH_TEST; then
    case $BATCH_QUEUE_TYPE in 
        LSF) # Create a meaningful job string, so unfinished jobs can be identified easily. 
            jobString=`getJobString $WRF_TYPE $PARALLEL_TYPE $NAMELIST_PATH`
            # Look for time control spec at end of namelist
            runTime=`grep LSF_TIME $testDir/namelist.input | cut -d '=' -f 2`
            if [ -z "$runTime" ]; then
               runTime="0:05"
            fi
            BSUB="bsub -q $TEST_QUEUE -P $BATCH_ACCOUNT -n $NUM_PROC -a poe -W $runTime -J $jobString -o test.out -e test.err -cwd $testDir "
            echo $BSUB > $testDir/submitCommand
            $BSUB < $testDir/test.sh
            ;;
        NQS) # Create a meaningful job string, so unfinished jobs can be identified easily. 
            jobString=`getJobString $WRF_TYPE $PARALLEL_TYPE $NAMELIST_PATH`
            # Look for time control spec at end of namelist
            runTime=`grep NQS_TIME $testDir/namelist.input | cut -d '=' -f 2`
            if [ -z "$runTime" ]; then
               runTime="0:05:00"
            fi
            BSUB="qsub -V -q janus-debug -l nodes=1:ppn=$NUM_PROC,walltime=$runTime -N $jobString -o $testDir/test.out -e $testDir/test.err -d $testDir"
            echo $BSUB > $testDir/submitCommand
            $BSUB $testDir/test.sh
            ;;
        *)  echo "Error: Unknown OS type '$OS_NAME'!"
            exit 2
    esac
else
    cd $testDir
    . $testDir/test.sh
fi


