# lua-resty-fastacl

# Install
  luarocks make
  
# configure
  nginx.conf
  http {
    include fastacl/fastacl.conf;
    init_worker_by_lua_block {
        require("resty.fastacl").init()
    }
    server {
      location / {
        require("resty.fastacl").check()
      }
    }
  }
  
  etcd config in lua file
  local etcd_conf = {...}
  
# Test
  ./fastacl_test_case.sh
