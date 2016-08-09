'''
@author: ppetrov
'''
import csv
import re, os, glob, commands, sys
from testrail import *

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

    # Extracting Average and Std.Dev.metrics
    with open(synthesis_file, 'rb') as synth_report_csv_file:
        for test_operation_name in reports[curr_test_plan_name].keys():
            operation_stats_record = commands.getstatusoutput("cat " + synthesis_file + " | grep -i '^" + test_operation_name + "'")[1].replace('"', r'\"')\
                                                                                                                                    .replace('(', r'\(')\
                                                                                                                                    .replace(')', r'\)')
            parsed_record = operation_stats_record.split(",")
            #reports[curr_test_plan_name][test_operation_name]['average'] = parsed_record[2]
            reports[curr_test_plan_name][test_operation_name]['std.dev.'] = parsed_record[6]


#print reports
#[9.1][Performance] Keystone Performance Testing
test_run_id = testrail_client.send_post('add_run/3',{"suite_id": 4275,\
                                             "name": "To_delete [integration example]",\
                                             "assignedto_id": 89,\
                                             "milestone_id": 34,\
                                             "include_all": 0,\
                                             "case_ids": test_cases})['id']
#print "test_run_id: " + str(test_run_id)

for test_report in reports.keys():
    print "\nAdding results for test: " + test_report + "to TestRail run " + str(test_run_id)
    test_operations = reports.get(test_report)
    for test_operation in test_operations.keys():
        # Extract testCase Id for TestRail (those Ids were created while testSuite creation
        # and written down into JMeter tests for future results mapping)
        test_case_id = test_operation.split("#id")[1]
        print "TestCase ID (TestRail): " + test_case_id
        print test_operations.get(test_operation)
        median = int(float(test_operations.get(test_operation)['percentiles']['50.0']))
        stdev = int(float(test_operations.get(test_operation)['std.dev.']))
        print testrail_client.send_post("add_result_for_case/" + str(test_run_id) + "/" + str(test_case_id), {"status_id": 1,\
                                                                                              "created_by": 89,\
                                                                                              "elapsed": "50S",\
                                                                                              "comment":"All the results are pointed in milliseconds.",
                                                                                              "custom_throughput":median,\
                                                                                              "custom_stdev":stdev})