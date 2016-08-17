'''
@author: ppetrov
'''
import csv
import re, os, glob, commands, sys
from testrail import *
from types import NoneType

if len(sys.argv) >= 3:
    reports_home = sys.argv[1]
    jmx_home = sys.argv[2]
else:
    jmx_home="/media/WORK_DATA/Installs/test tools/JMeter/apache-jmeter-3.0/bin/"
    reports_home = '/var/lib/jenkins/workspace/RunJMeter/testrun_results_1procecces_2threads_05.08.2016_15-28-51/'

reports = {}
test_cases = []

# Connecting to TestRail
testrail_client = APIClient('https://mirantis.testrail.com/')
testrail_client.user = 'sgudz@mirantis.com'
testrail_client.password = 'qwertY123'

#Getting expected result for each of test cases of test suite 4275 in TestRail
testrail_expected_results = {}
testrail_test_cases = testrail_client.send_get('get_cases/3&suite_id=4275')
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
        statistic_records = commands.getstatusoutput("cat " + percentiles_file + " | grep -iE '^(50\.0)'")[1].split("\n")
        
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
            #reports[curr_test_plan_name][test_operation_name]['average'] = parsed_record[2]
            reports[curr_test_plan_name][test_operation_name]['std.dev.'] = parsed_record[6]
            reports[curr_test_plan_name][test_operation_name]['percent_of_errors'] = parsed_record[7].split("%")[0]
            reports[curr_test_plan_name][test_operation_name]['throughput'] = parsed_record[8]


#print reports

#Creating test run to save test results 
test_run_id = testrail_client.send_post('add_run/3',{"suite_id": 4275,\
                                             "name": "To_delete [integration example]",\
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
        median = int(float(test_operations.get(test_operation)['percentiles']['50.0']))
        stdev = int(float(test_operations.get(test_operation)['std.dev.']))
        
        # Starting "custom_test_case_steps_results" populating for a current test case
        testrail_all_additional_results = []
        low_rps = True
        many_errors = True
        high_resp_time_median = True
        high_resp_time_stdev = True
        
        for param_name, expected_value in testrail_expected_results.get(int(test_case_id)).items():              
            if param_name == u'Check [Real RPS]':
                actual = test_operations.get(test_operation)['throughput']
                if int(float(actual)) >= int(expected_value)*0.9:
                    low_rps = False
                    status_id = 1
                else:
                    status_id = 5
            elif param_name == u'Check [Percent of Errors]':
                actual = test_operations.get(test_operation)['percent_of_errors']
                if int(float(actual)) < int(expected_value):
                    many_errors = False
                    status_id = 1
                else:
                    status_id = 5                
            elif param_name == u'Check [ResponseTime Median, ms]':
                actual = str(median)
                if int(float(actual)) <= int(float(expected_value))*1.1:
                    high_resp_time_median = False
                    status_id = 1
                else:
                    status_id = 5                    
            elif param_name == u'Check [ResponseTime Stdev, ms]':
                actual = str(stdev)
                if int(float(actual)) <= int(float(expected_value))*1.1:
                    high_resp_time_stdev = False
                    status_id = 1
                else:
                    status_id = 5
                    
            testrail_all_additional_results.append({u'content':param_name,u'expected':expected_value,u'actual':actual,u'status_id':status_id})        
        #print testrail_all_additional_results
        
        #Set overall "status_id" for test case based on results for each metric 
        test_case_global_status_id = 1
        if (low_rps or many_errors or high_resp_time_median or high_resp_time_stdev): test_case_global_status_id = 5
        
        #Sending results to TestRail
        print testrail_client.send_post("add_result_for_case/" + str(test_run_id) + "/" + test_case_id, {"status_id": test_case_global_status_id,\
                                                                                              "created_by": 89,\
                                                                                              "comment":"All the results are pointed in milliseconds.",
                                                                                              "custom_throughput":median,\
                                                                                              "custom_stdev":stdev,\
                                                                                              "custom_test_case_steps_results":testrail_all_additional_results})