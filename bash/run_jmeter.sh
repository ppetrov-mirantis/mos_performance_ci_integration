# Source dirs
jmeter_env_archname="jmeter_tests.tar.gz"
jmeter_env_archpath="/media/WORK_DATA/Code/deployment_n_configuring/ci_automation"
# Destination dirs
tests_basedir="jmeter_tests"
jmeter_dest_home="$tests_basedir/jmeter"
scenarios_dest_home="$tests_basedir/scenarios"
testresults_dest_home="$tests_basedir/results"
utils_dest_home="$tests_basedir/utils"

echo "Connecting to $FUEL_IP fuel-node..."
ssh-keygen -f ~/.ssh/known_hosts -R $FUEL_IP
sshpass -p r00tme scp root@$FUEL_IP:.ssh/id_rsa ~/jmeter_keystone_testenv.key

fuel_ssh_connection="sshpass -p r00tme ssh -o StrictHostKeyChecking=no root@$FUEL_IP"

# Getting address of host to deploy and run tests. 
jmeter_deployment_node_id=10000
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

# Allowing direct access from all hosts to target JMeter-node (using internal node-ip)
echo "Adding iptables rules (if they're not exist) allowing to access all hosts to target JMeter-node"
$fuel_ssh_connection "ssh $jmeter_deployment_node_ip iptables -C INPUT -j ACCEPT" || $fuel_ssh_connection "ssh $jmeter_deployment_node_ip iptables -I INPUT -j ACCEPT"
$fuel_ssh_connection "ssh $jmeter_deployment_node_ip iptables -C OUTPUT -j ACCEPT" || $fuel_ssh_connection "ssh $jmeter_deployment_node_ip iptables -I OUTPUT -j ACCEPT"

# Dsicovering node-ip address (using it's "br-ex" interface)
jmeter_deployment_node_ip=$($fuel_ssh_connection "ssh $jmeter_deployment_node_ip" "ifconfig br-ex" | grep -oP '([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})' | head -n1) || exit 1

echo "Deploying JMeter to $jmeter_deployment_node_ip compute node [fuel node-$jmeter_deployment_node_id]"

# Set deployment node connection string using external node-ip ("br-ex" interface ip)
jmeter_node_ssh_connection="ssh -o IdentityFile=~/jmeter_keystone_testenv.key -o StrictHostKeyChecking=no root@$jmeter_deployment_node_ip"

# Create target directory
$jmeter_node_ssh_connection "rm -rf $tests_basedir && mkdir $tests_basedir" || exit 1


echo "Deploying JMeter to $jmeter_deployment_node_ip host"
# Installing java to JMeter-node if necessary
java_packeges=$($jmeter_node_ssh_connection "dpkg -l | grep -w 'openjdk\-8\-jdk\|jre' | tr -s \" \" | cut -f 2 -d \" \"") || exit 1
java_pack_amount=$($java_packeges | wc -l)
if [ $java_pack_amount -lt 1 ]
  then
    echo "Installing java..."
    $jmeter_node_ssh_connection "apt-get --yes install openjdk-8-jre" || exit 1
  else
    echo "Java packages are already installed: $java_packeges"
fi

source_path=$jmeter_env_archpath/$jmeter_env_archname
upload_path=$tests_basedir/$jmeter_env_archname
jmeter_node_connect_to_upload="scp -o IdentityFile=~/jmeter_keystone_testenv.key -o StrictHostKeyChecking=no $source_path root@$jmeter_deployment_node_ip:~/$upload_path"
echo "Uploading JMeter environment..."
echo $jmeter_node_connect_to_upload
$jmeter_node_connect_to_upload
echo "Unpacking JMeter environment..."
$jmeter_node_ssh_connection "tar -zxf $upload_path -C ~/$tests_basedir && chmod 755 ~/$tests_basedir -R"


echo "Will run tests for such configuration pairs of Keystone processes/threads: [$(echo $KEYSTONE_CONFIGS | tr \" \")]"
for config_item in $KEYSTONE_CONFIGS; do
  ks_processes=$(echo $config_item | cut -f1 -d",")
  ks_threads=$(echo $config_item | cut -f2 -d",")
  echo "\n--------======== Starting Keystone tests for $ks_processes process(es) and $ks_threads thread(s) on each controller========--------"

  #Reconfiguring controllers
  controllers=$($fuel_ssh_connection "fuel nodes" | grep controller | cut -f 5 -d "|" | tr -d " " | sort) || exit 1
  for controller_ip in $controllers; do
    echo "\nReconfiguring $controller_ip controller node ..."
    $fuel_ssh_connection ssh root@$controller_ip "sed -i 's/processes=[0-9]*/processes=$ks_processes/g' /etc/apache2/sites-enabled/05-keystone_wsgi_*"
    $fuel_ssh_connection ssh root@$controller_ip "sed -i 's/threads=[0-9]*/threads=$ks_threads/g' /etc/apache2/sites-enabled/05-keystone_wsgi_*"
    echo "Restarting Apache2 Server on $controller_ip controller node ..."
    $fuel_ssh_connection ssh root@$controller_ip "service apache2 restart"
    #$fuel_ssh_connection ssh root@$controller_ip "cat /etc/apache2/sites-enabled/05-keystone_wsgi_* | grep WSGIDaemonProcess"
  done

  # Run Jmeter tests for current Keystone configuration
  for jmx_file in $($jmeter_node_ssh_connection "ls ~/$scenarios_dest_home | grep .jmx" || exit 1); do

    jtl_filename_unescaped="$($jmeter_node_ssh_connection "echo ~/")$testresults_dest_home/$(echo $jmx_file | cut -f 1 -d ".").jtl" # obtaining fullpath for each *.jtl-file
    jtl_filename=$(echo $jtl_filename_unescaped | sed 's/[/_]/\\&/g') # escaping special symbols in the path string

    $jmeter_node_ssh_connection "sed -i -E 's/(<stringProp.*>).*.jtl(<\/stringProp>)/\1$jtl_filename\2/' ~/$scenarios_dest_home/$jmx_file" || exit 1 # replacing *.jtl-paths in scenarios
    echo "\nExecuting scenario '$jmx_file' saving results to '$jtl_filename'"
    scen_exec_string="$jmeter_node_ssh_connection ~/$jmeter_dest_home/bin/jmeter -n -t ~/$scenarios_dest_home/$jmx_file" || exit 1
    echo $scen_exec_string
    $scen_exec_string
    echo "Scenario '$jmx_file' is finished."

    percentilles_report_file="$(echo $jmx_file | cut -f 1 -d ".")_percentilles_report.csv"
    synthesis_report_file="$(echo $jmx_file | cut -f 1 -d ".")_synthesis_report.csv"
    $jmeter_node_ssh_connection "java -jar ~/$jmeter_dest_home/lib/ext/CMDRunner.jar --tool Reporter --generate-csv ~/$testresults_dest_home/$percentilles_report_file --input-jtl $jtl_filename_unescaped --plugin-type ResponseTimesPercentiles --start-offset 10 --end-offset 40"
    $jmeter_node_ssh_connection "java -jar ~/$jmeter_dest_home/lib/ext/CMDRunner.jar --tool Reporter --generate-csv ~/$testresults_dest_home/$synthesis_report_file --input-jtl $jtl_filename_unescaped --plugin-type SynthesisReport --start-offset 10 --end-offset 40"

    test_plan_name=$($jmeter_node_ssh_connection cat $($jmeter_node_ssh_connection "echo ~/")$testresults_dest_home/$jmx_file | grep -oP 'testclass="TestPlan" testname="\K[^"]*')
    percentilles_report_file="$(echo $jmx_file | cut -f 1 -d ".")_percentilles_report.csv"
    synthesis_report_file="$(echo $jmx_file | cut -f 1 -d ".")_synthesis_report.csv"
    echo "Building report for scenario "$test_plan_name""
    $jmeter_node_ssh_connection "java -jar ~/$jmeter_dest_home/lib/ext/CMDRunner.jar --tool Reporter --generate-csv ~/$testresults_dest_home/$percentilles_report_file --input-jtl $jtl_filename_unescaped --plugin-type ResponseTimesPercentiles --start-offset 20"
    $jmeter_node_ssh_connection "java -jar ~/$jmeter_dest_home/lib/ext/CMDRunner.jar --tool Reporter --generate-csv ~/$testresults_dest_home/$synthesis_report_file --input-jtl $jtl_filename_unescaped --plugin-type SynthesisReport --start-offset 20"
  done

  results_storage_dir=$(printf "testrun_results_%sprocecces_%sthreads_$(date +%d.%m.%Y_%H-%M-%S)" $ks_processes $ks_threads)
  mkdir $results_storage_dir
  echo "Saving results to $(pwd)/$results_storage_dir on Jenkins node"
  $jmeter_node_ssh_connection "python ~/$utils_dest_home/jmeter_reports_parser.py ~/$testresults_dest_home/ ~/$scenarios_dest_home/"
  scp -r -o IdentityFile=~/jmeter_keystone_testenv.key -o StrictHostKeyChecking=no root@$jmeter_deployment_node_ip:~/$testresults_dest_home/* $results_storage_dir/ #&& $jmeter_node_ssh_connection "rm -r ~/$testresults_dest_home/*"

done
