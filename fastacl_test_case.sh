#!/bin/sh

set_rule()
{
	key=$1
	val=$2

	#echo $key $val
	ret=`etcdctl --user=waf --password=waf put ${key} ${val} --endpoints=\"192.168.108.113:2379\"`
	echo $ret
}

unset_rule()
{
	key=$1
	#echo $key 
	cmd="etcdctl --user=waf --password=waf del ${key} --endpoints=\"192.168.108.113:2379\""
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

	sleep 3s
	send_req $@
	res_status=$?
	echo "ret:" ${res_status} "verify: "${status}
	if test $[res_status] -eq $[status]
	then
		echo "test rule ${key} ${val} OK!"
	else
		echo "test ${key} ${val} Faliure!"
	fi

	unset_rule ${key}
	sleep 1s
	send_req $@
	res_status=$?
	if test $[res_status] -ne $[status]
	then
		echo "check delete ${key} ${val} OK!"
	else
		echo "test ${key} ${val} Faliure!"
	fi
}

#sample_test_rule /waf/service/fastacl/prd/t2/var-ip+var-host+var-path:6664a229f7b313a62c238bc811559496 \"1.1.1.1www.test.com/api\" 204 http://192.168.108.112/api www.test.com waf-test 1.1.1.1
sample_test_rule /waf/service/fastacl/prd/t2/var-ip+var-host+var-path+rca-_m:53d676717d97090c5f0f5fc399a045dc \"1.1.1.1www.test.com/apidevice\" 204 http://192.168.108.112/api?_m=device www.test.com waf-test 1.1.1.1
