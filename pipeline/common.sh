# to be sourced by other scripts, no shebang is needed
# it requires bash 4.x to work as we used array here
# use 'base -version' to check the version

unset -v PROGDIR
case "${0}" in
*/*) PROGDIR="${0%/*}";;
*) PROGDIR=.;;
esac

ROOTDIR=${PROGDIR}/..
CONFIG_DIR=$(realpath $ROOTDIR)/configs
JQ='jq -M -r'

declare -A configs
declare -A managednodes
declare -a genesis

function expense
{
   local step=$1
   local duration=$SECONDS
   logging $step took $(( $duration / 60 )) minutes and $(( $duration % 60 )) seconds
}

function verbose
{
   [ $VERBOSE ] && echo $@
}

function errexit
{
   logging "$@ . Exiting ..."
   exit -1
}

function _join
{
   local IFS="$1"; shift; echo "$*"; 
}

function logging
{
   echo $(date) : $@
   SECONDS=0
}

function read_profile
{
   BENCHMARK_PROFILE=$1
   [ ! -e $BENCHMARK_PROFILE ] && errexit "can't find the benchmark config file: $BENCHMARK_PROFILE"

   logging reading benchmark config file: $BENCHMARK_PROFILE

   keys=(
      description libp2p genesis aws.profile azure.num_vm azure.regions
      leader.regions leader.num_vm leader.type leader.root
      client.regions client.num_vm client.type
      benchmark.shards benchmark.duration benchmark.dashboard benchmark.crosstx
      benchmark.attacked_mode benchmark.init_retry benchmark.archival
      logs.leader logs.client logs.validator logs.soldier logs.db
      parallel dashboard.server dashboard.name dashboard.port dashboard.reset
      userdata flow.wait_for_launch flow.reserved_account flow.rpczone
      benchmark.minpeer benchmark.even_shard benchmark.peer_per_shard
      benchmark.commit_delay benchmark.log_conn
      explorer.server explorer.name explorer.port explorer.reset
      txgen.ip txgen.port txgen.enable
      bootnode.port bootnode.server bootnode.key bootnode.enable bootnode.p2pkey
      bootnode.log_conn
      bootnode1.port bootnode1.server bootnode1.key bootnode1.enable
      bootnode1.p2pkey bootnode1.log_conn
      wallet.enable
   )
   
   managednodekey=.managednodes.nodes
   nodekeys=( role ip port key )

   for k in ${keys[@]}; do
      configs[$k]=$($JQ .$k $BENCHMARK_PROFILE)
   done

   nodes_num=$($JQ " $managednodekey | length " $BENCHMARK_PROFILE)
   configs[managednodes.num]=$nodes_num
   i=0
   while [ $i -lt $nodes_num ]; do
      for k in ${nodekeys[@]}; do
         configs[managednode$i.$k]=$($JQ " $managednodekey[$i].$k " $BENCHMARK_PROFILE)
      done
      ((i++))
   done

   if [ "${configs[genesis]}" != "null" ]; then
      genesis=( $(cat $CONFIG_DIR/${configs[genesis]}) )
   fi
}

function gen_userdata
{
   BUCKET=$1
   FOLDER=$2
   USERDATA=$3

   [ ! -e $USERDATA ] && errexit "can't find userdata file: $USERDATA"

   echo "generating userdata file"
   sed "-e s,^BUCKET=.*,BUCKET=${BUCKET}," -e "s,^FOLDER=.*,FOLDER=${FOLDER}/," $USERDATA > $USERDATA.aws
   verbose ${configs[@]}
}

# _find_available_node_index return an available node index after skipping the reserved account index
# the reserved account index is for external node runners
# due to the current limitation of only genesis nodes can join the consensus and get rewards
function _find_available_node_index
{
   local i=$1
   local found=false

   while [ "$found" != "true" ]; do
      i=$((i+1))
      if [ "${configs[benchmark.even_shard]}" != "true" ]; then
         mod=$(( $i % ${configs[benchmark.peer_per_shard]} ))
         if [ $mod == 0 ]; then
            continue
         fi
      fi
      if [[ "${configs[flow.reserved_account]}" =~ ",$i," ]]; then
         continue
      else
         found=true
      fi
   done
   echo $i
}

# _is_archival checks if the current node is launched as archival node
# return 0 means pass/true in shell, is archival
# return 1 means error/false in shell, is not archival
function _is_archival
{
   local i=$1

   if [[ "${configs[benchmark.archival]}" =~ ",$i," ]]; then
      return 0
   fi
   return 1
}

##########

if [ "$(uname -s)" == "Darwin" ]; then
   TIMEOUT=gtimeout
else
   TIMEOUT=timeout
fi
