#!/bin/sh

set_rule()
{
	key=$1
	val=$2

	#echo $key $val
	ret=`etcdctl --user=waf --password=waf put ${key} ${val} --endpoints=\"127.0.0.1:80\"`
	echo $ret
}

unset_rule()
{
	key=$1
	#echo $key 
	cmd="etcdctl --user=waf --password=waf del ${key} --endpoints=\"127.0.0.1:80\""
	echo $cmd
	return `$cmd`

}

send_req()
{
	url=$4
	host=$5	
	ua=$6
	ip=$7
	#`curl -v ${url} -H Host:${host}`
	ret=`curl -o /dev/null -s -w %{http_code} ${url} -H Host:${host} -H User-Agent:${ua} -H X-Forwarded-For:${ip}`
	#echo $ret
	return $ret
}

sample_test_rule()
{
	key=$1
	val=$2
	status=$3

	send_req $@
	res_status=$?
	echo $res_status
	if test $[res_status] -ne $[status]
	then
		echo "check ${key} ${val} OK!"
	else
		echo "test ${key} ${val} Faliure!"
	fi
	sleep 1s
	set_rule ${key} ${val}

	sleep 1s
	send_req $@
	res_status=$?
	echo "ret:" ${res_status} "verify: "${status}
	if test $[res_status] -eq $[status]
	then
		echo "test ${key} ${val} OK!"
	else
		echo "test ${key} ${val} Faliure!"
	fi

	unset_rule ${key}
	sleep 1s
	send_req $@
	res_status=$?
	if test $[res_status] -ne $[status]
	then
		echo "check ${key} ${val} OK!"
	else
		echo "test ${key} ${val} Faliure!"
	fi
}

sample_test_rule /waf/service/fastacl/prd/t1/ip+host+path:6664a229f7b313a62c238bc811559496 \"1.1.1.1www.test.com/api\" 204 http://192.168.108.112/api www.test.com waf-test 1.1.1.1
