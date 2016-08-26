'''
@author: ppetrov
'''
import csv
import re, os, glob, commands, sys
from datetime import datetime
from testrail import *
from types import NoneType

if len(sys.argv) >= 4:
    reports_home = sys.argv[1]
    jmx_home = sys.argv[2]
    estimated_test_duration = "**Test duration:** " + str(sys.argv[3]) + " secs."
    keystone_configuration = "\nEach controller was configured to use _**{0}** Keystone processes_ and _**{1}** threads_ per process".format(str(sys.argv[4]), str(sys.argv[5]))
else:
    jmx_home="/media/WORK_DATA/Installs/test tools/JMeter/apache-jmeter-3.0/bin/"
    #jmx_home="/media/mirantis_ws_disk/Installs/test tools/JMeter/apache-jmeter-3.0/bin/"
    reports_home = '/media/WORK_DATA/Code/deployment_n_configuring/ci_automation/testrun_results_6procecces_3threads_09.08.2016_17-06-07/'
    #reports_home = '/media/mirantis_ws_disk/Code/deployment_n_configuring/ci_automation/testrun_results_6procecces_3threads_09.08.2016_17-06-07/'
    estimated_test_duration = "not logged"
    keystone_configuration = "\nKeystone configuration is unknown"

reports = {}
test_cases = []

# Connecting to TestRail
testrail_client = APIClient('https://mirantis.testrail.com/')
testrail_client.user = 'sgudz@mirantis.com'
testrail_client.password = 'qwertY123'
test_suite_id = 4275

#Getting expected result for each of test cases of test suite 4275 in TestRail
testrail_expected_results = {}
testrail_test_cases = testrail_client.send_get('get_cases/3&suite_id=' + str(test_suite_id))
for testrail_test_case in testrail_test_cases:
    expected_results_list = {}
    test_expectations = testrail_test_case['custom_test_case_steps']
    if type(test_expectations) != NoneType:
        for test_expectation in testrail_test_case['custom_test_case_steps']:
            if test_expectation['expected'] != '':       
                expected_results_list[test_expectation['content']] = test_expectation['expected']
        if len(expected_results_list) != 0:
            testrail_expected_results[testrail_test_case['id']] = expected_results_list


for jmx_name in glob.glob(jmx_home + "*.jmx"):
    f_content = open(jmx_name, "rb").read()
    curr_test_plan_name = re.search('testclass="TestPlan" testname="([^"]*)', f_content).group(1)

    reports[curr_test_plan_name] = {}
    
    basename = os.path.splitext(os.path.basename(jmx_name))[0]    
    percentiles_file = reports_home + basename + '_percentilles_report.csv'
    synthesis_file = reports_home + basename + '_synthesis_report.csv'
    
    # Extracting percentiles metrics
    with open(percentiles_file, 'rb') as synth_report_csv_file:        
        fields = csv.DictReader(synth_report_csv_file, quoting=csv.QUOTE_NONE).fieldnames
        statistic_records = commands.getstatusoutput("cat " + percentiles_file + " | grep -iE '^(50\.0|90\.0)'")[1].split("\n")
        
        for index in range(len(fields)):
            test_operation_name = fields[index]            
            if test_operation_name != "Percentiles" and test_operation_name.find("#") != -1:
                reports[curr_test_plan_name][test_operation_name] = {}
                reports[curr_test_plan_name][test_operation_name]['percentiles'] = {}
                
                # Extract testCase Id for TestRail (those Ids were created while testSuite creation
                # and written down into JMeter tests for future results mapping) 
                test_cases.append(test_operation_name.split("#id")[1])
                # Fill percentile values for each operation
                for stats_record in statistic_records:
                    stats_list = stats_record.split(",")
                    reports[curr_test_plan_name][test_operation_name]['percentiles'][stats_list[0]] = stats_list[index] 

    # Extracting Throughput, Std.Dev. and Errors% metrics
    with open(synthesis_file, 'rb') as synth_report_csv_file:
        for test_operation_name in reports[curr_test_plan_name].keys():
            operation_stats_record = commands.getstatusoutput("cat " + synthesis_file + " | grep -i '^" + test_operation_name + "'")[1].replace('"', r'\"')\
                                                                                                                                    .replace('(', r'\(')\
                                                                                                                                    .replace(')', r'\)')
            parsed_record = operation_stats_record.split(",")
            reports[curr_test_plan_name][test_operation_name]['std.dev.'] = parsed_record[6]
            reports[curr_test_plan_name][test_operation_name]['errors_percent'] = parsed_record[7].split("%")[0]
            reports[curr_test_plan_name][test_operation_name]['throughput'] = parsed_record[8]

#print reports

#Creating test run to save test results
product_version = "9.X" # Until it's not clarified where to get from
repo_snapshot_id = "XXX" # Until it's not clarified where to get from
test_suite_name = testrail_client.send_get('get_suite/' + str(test_suite_id))['name']
test_run_name = "To_delete: {0} {1} #{2}-{3}".format(product_version, test_suite_name, repo_snapshot_id, datetime.now().strftime("%d/%m/%Y-%H:%M"))
test_run_id = testrail_client.send_post('add_run/3',{"suite_id": test_suite_id,\
                                             "name": test_run_name,\
                                             "assignedto_id": 89,\
                                             "milestone_id": 34,\
                                             "include_all": 0,\
                                             "case_ids": test_cases})['id']

# Collecting necessary test results from data structures and sending it to TestRail via HTTP
for test_report in reports.keys():
    test_operations = reports.get(test_report)
    for test_operation in test_operations.keys():
        # Extract testCase Id for TestRail (those Ids were created while testSuite creation
        # and written down into JMeter tests for future results mapping)
        test_case_id = test_operation.split("#id")[1]
        
        test_operation_stats = test_operations.get(test_operation)
        median = int(float(test_operation_stats['percentiles']['50.0']))
        stdev = int(float(test_operation_stats['std.dev.']))
        
        # Starting "custom_test_case_steps_results" populating for a current test case
        testrail_all_additional_results = []
        low_rps = True
        many_errors = True
        high_resp_time_median = True
        high_90_percentile = True
        
        for param_name, expected_value in testrail_expected_results.get(int(test_case_id)).items():
            status_id = 5 # Default TestStep status. Can be changed below.
                          
            if param_name == u'Check [Real Throughput; rps]':
                actual = test_operation_stats['throughput']
                if int(float(actual)) >= int(expected_value)*0.9:
                    low_rps = False
                    status_id = 1
            elif param_name == u'Check [Errors percent; percent]':
                actual = test_operation_stats['errors_percent']
                if int(float(actual)) < int(expected_value):
                    many_errors = False
                    status_id = 1
            elif param_name == u'Check [Response Time Median; 50_percentile_ms]':
                actual = str(median)
                if int(float(actual)) <= int(float(expected_value))*1.1:
                    high_resp_time_median = False
                    status_id = 1
            elif param_name == u'Check [Response Time 90% Line; 90_percentile_ms]':
                actual = test_operation_stats['percentiles']['90.0']
                if int(float(actual)) <= int(float(expected_value))*1.1:
                    high_90_percentile = False
                    status_id = 1
                    
            testrail_all_additional_results.append({u'content':param_name,u'expected':expected_value,u'actual':actual,u'status_id':status_id})
        #print testrail_all_additional_results
        
        #Set overall "status_id" for test case based on results for each metric 
        test_case_global_status_id = 1
        if (low_rps or many_errors or high_resp_time_median or high_90_percentile): test_case_global_status_id = 5
        
        #Sending results to TestRail
        print testrail_client.send_post("add_result_for_case/" + str(test_run_id) + "/" + test_case_id, {"status_id": test_case_global_status_id,\
                                                                                              "created_by": 89,\
                                                                                              "comment": estimated_test_duration + keystone_configuration,\
                                                                                              "custom_test_case_steps_results":testrail_all_additional_results})
