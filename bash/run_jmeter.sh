# Source dirs
#jmeter_env_archname="jmeter_long_tests.tar.gz"
jmeter_env_archname="jmeter_tests.tar.gz"
jmeter_env_archpath="/media/WORK_DATA/Code/deployment_n_configuring/ci_automation"
# Destination dirs
tests_basedir="jmeter_tests"
jmeter_dest_home="$tests_basedir/jmeter"
scenarios_dest_home="$tests_basedir/scenarios"
testresults_dest_home="$tests_basedir/results"
utils_dest_home="$tests_basedir/utils"

login=""
password=""

echo "Connecting to $FUEL_IP fuel-node..."
ssh-keygen -f ~/.ssh/known_hosts -R $FUEL_IP
(rm ~/jmeter_keystone_testenv.key 2>/dev/null || echo > /dev/null) && sshpass -p $password scp -o StrictHostKeyChecking=no $login@$FUEL_IP:.ssh/id_rsa ~/jmeter_keystone_testenv.key || exit 1

fuel_ssh_connection="sshpass -p $password ssh -o StrictHostKeyChecking=no $login@$FUEL_IP"

# Getting address of host to deploy and run tests.
jmeter_deployment_node_id=1000000
jmeter_deployment_node_ip=''
compute_nodes=$($fuel_ssh_connection "fuel nodes" | grep compute | cut -f 1,5 -d "|" | tr -d " " | sort) || exit 1
for compute in $compute_nodes; do
  cluster_node_id=$(echo $compute | cut -f 1 -d "|")
  if [ $cluster_node_id -lt $jmeter_deployment_node_id ] # find the node with the minimal id-value
    then
      jmeter_deployment_node_id=$cluster_node_id
      jmeter_deployment_node_ip=$(echo $compute | cut -f 2 -d "|")
  fi
done

# Getting Keystone internal IP-address
contoller_ip=$($fuel_ssh_connection "fuel nodes" | grep contr -m 1 | cut -f 5 -d "|" | tr -d " ")
keystone_internal_ip=$($fuel_ssh_connection ssh $contoller_ip "cat openrc" | grep OS_AUTH_URL | grep -oP '([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})')
echo "Keystone internal IP: $keystone_internal_ip"

# Allowing direct access from all hosts to target JMeter-node (using internal node-ip). . .
echo "Adding iptables rules (if they're not exist) allowing to access all hosts to target JMeter-node"
$fuel_ssh_connection "ssh $jmeter_deployment_node_ip iptables -C INPUT -j ACCEPT" || $fuel_ssh_connection "ssh $jmeter_deployment_node_ip iptables -I INPUT -j ACCEPT"
$fuel_ssh_connection "ssh $jmeter_deployment_node_ip iptables -C OUTPUT -j ACCEPT" || $fuel_ssh_connection "ssh $jmeter_deployment_node_ip iptables -I OUTPUT -j ACCEPT"

# Dsicovering node-ip address using it's "br-ex" interface (public addresses feature should be set for computes before cluster deployment)
jmeter_deployment_node_ip=$($fuel_ssh_connection "ssh $jmeter_deployment_node_ip" "ifconfig br-ex" | grep -oP '([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})' | head -n1) || exit 1
echo "Deploying JMeter to $jmeter_deployment_node_ip compute node [fuel node-$jmeter_deployment_node_id]"

# Set deployment node connection string using external node-ip ("br-ex" interface ip)
jmeter_node_ssh_connection="ssh -o IdentityFile=~/jmeter_keystone_testenv.key -o StrictHostKeyChecking=no $login@$jmeter_deployment_node_ip"

# Create target directory
$jmeter_node_ssh_connection "(rm -r $tests_basedir 2>/dev/null || echo > /dev/null) && mkdir $tests_basedir" || exit 1

# Install java to JMeter-node if necessary
java_pkgs_number=$($jmeter_node_ssh_connection "dpkg-query -l *jre | grep ii | tr -s \" \" | cut -f 2 -d \" \"" | wc -l) || exit 1
if [ $java_pkgs_number -lt 1 ]
  then
    echo "Installing java..."
    $jmeter_node_ssh_connection "apt-get update && apt-get --yes --force-yes install openjdk-8-jre" || exit 1
  else
    echo "Java packages are already installed: $java_packages"
fi

# Upload test infrastructure
source_path=$jmeter_env_archpath/$jmeter_env_archname
upload_path=$tests_basedir/$jmeter_env_archname
jmeter_node_connect_to_upload="scp -o IdentityFile=~/jmeter_keystone_testenv.key -o StrictHostKeyChecking=no $source_path $login@$jmeter_deployment_node_ip:~/$upload_path"
echo "Uploading JMeter environment..."
echo $jmeter_node_connect_to_upload
$jmeter_node_connect_to_upload
echo "Unpacking JMeter environment..."
$jmeter_node_ssh_connection "tar -zxf $upload_path -C ~/$tests_basedir && chmod 755 ~/$tests_basedir -R"

# Perform tests for keystone configurations
echo "Will run tests for such configuration pairs of Keystone processes/threads: [$(echo $KEYSTONE_CONFIGS | tr \" \")]"
for config_item in $KEYSTONE_CONFIGS; do
  ks_processes=$(echo $config_item | cut -f1 -d",")
  ks_threads=$(echo $config_item | cut -f2 -d",")
  echo "\n--------======== Starting Keystone tests for $ks_processes process(es) and $ks_threads thread(s) on each controller========--------"

  #Reconfiguring controllers
  controllers=$($fuel_ssh_connection "fuel nodes" | grep controller | cut -f 5 -d "|" | tr -d " " | sort) || exit 1
  for controller_ip in $controllers; do
    echo "\nReconfiguring $controller_ip controller node ..."
    $fuel_ssh_connection ssh $login@$controller_ip "sed -i 's/processes=[0-9]*/processes=$ks_processes/g' /etc/apache2/sites-enabled/05-keystone_wsgi_*"
    $fuel_ssh_connection ssh $login@$controller_ip "sed -i 's/threads=[0-9]*/threads=$ks_threads/g' /etc/apache2/sites-enabled/05-keystone_wsgi_*"
    echo "Restarting Apache2 Server on $controller_ip controller node ..."
    $fuel_ssh_connection ssh $login@$controller_ip "service apache2 restart"
    $fuel_ssh_connection ssh $login@$controller_ip "cat /etc/apache2/sites-enabled/05-keystone_wsgi_* | grep WSGIDaemonProcess"
  done

  # just wait after controllers restarted
  sleep 120

  # Run Jmeter tests for current Keystone configuration
  for jmx_file in $($jmeter_node_ssh_connection "ls ~/$scenarios_dest_home | grep .jmx" || exit 1); do

    jtl_filename_unescaped="$($jmeter_node_ssh_connection "echo ~/")$testresults_dest_home/$(echo $jmx_file | cut -f 1 -d ".").jtl" # obtaining fullpath for each *.jtl-file
    jtl_filename=$(echo $jtl_filename_unescaped | sed 's/[/_]/\\&/g') # escaping special symbols in the path string
    $jmeter_node_ssh_connection "sed -i -E 's/(<stringProp.*>).*.jtl(<\/stringProp>)/\1$jtl_filename\2/' ~/$scenarios_dest_home/$jmx_file" || exit 1 # replacing *.jtl-paths for each scenario
    $jmeter_node_ssh_connection "sed -i 's/\${KEYSTONE_IP}/$keystone_internal_ip/g' ~/$scenarios_dest_home/$jmx_file" || exit 1 # setting Keystone IP for each scenario
    
    echo "\nExecuting scenario '$jmx_file' saving results to '$jtl_filename_unescaped'"
    estimated_test_duration=$($jmeter_node_ssh_connection "cat ~/$scenarios_dest_home/$jmx_file" | grep -oP '((?<=<stringProp name="Hold">)|(?<=<stringProp name="RampUp">))(.*)(?=</stringProp>)' | awk '{SUM += $1} END {print SUM}')
    scen_exec_string="$jmeter_node_ssh_connection timeout --kill-after=5s --signal=9 $((estimated_test_duration+10)) ~/$jmeter_dest_home/bin/jmeter -n -t ~/$scenarios_dest_home/$jmx_file" || exit 1
    echo $scen_exec_string
    $scen_exec_string
    echo "Scenario '$jmx_file' is finished."

    percentilles_report_file="$(echo $jmx_file | cut -f 1 -d ".")_percentilles_report.csv"
    synthesis_report_file="$(echo $jmx_file | cut -f 1 -d ".")_synthesis_report.csv"
    echo "Building report for scenario "$jmx_file""
    $jmeter_node_ssh_connection "java -jar ~/$jmeter_dest_home/lib/ext/CMDRunner.jar --tool Reporter --generate-csv ~/$testresults_dest_home/$percentilles_report_file --input-jtl $jtl_filename_unescaped --plugin-type ResponseTimesPercentiles --start-offset 20"
    $jmeter_node_ssh_connection "java -jar ~/$jmeter_dest_home/lib/ext/CMDRunner.jar --tool Reporter --generate-csv ~/$testresults_dest_home/$synthesis_report_file --input-jtl $jtl_filename_unescaped --plugin-type SynthesisReport --start-offset 20"
  done

  # Save results to a local directory and send stats to TestRail
  results_storage_dir=$(printf "testrun_results_%sprocecces_%sthreads_$(date +%d.%m.%Y_%H-%M-%S)" $ks_processes $ks_threads)
  mkdir $results_storage_dir
  echo "Saving results to TestRail. . ."  
  $jmeter_node_ssh_connection "python ~/$utils_dest_home/jmeter_reports_parser.py ~/$testresults_dest_home/ ~/$scenarios_dest_home/ $estimated_test_duration $ks_processes $ks_threads $SNAPSHOT $FUEL_IP $jmeter_deployment_node_ip"
  echo "Saving result files to $(pwd)/$results_storage_dir directory on Jenkins node"
  scp -r -o IdentityFile=~/jmeter_keystone_testenv.key -o StrictHostKeyChecking=no $login@$jmeter_deployment_node_ip:~/$testresults_dest_home/* $results_storage_dir/ && $jmeter_node_ssh_connection "rm -r ~/$testresults_dest_home/*"

done
