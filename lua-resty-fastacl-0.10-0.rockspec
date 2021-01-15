package = "lua-resty-fastacl"
version = "0.10-0"
source = {
   url = "git://github.com/lqglqy/lua-resty-fastacl",
   tag = "v0.15"
}
description = {
   summary = "Lua HTTP fast access control for OpenResty / ngx_lua.",
   homepage = "https://github.com/lqglqy/lua-resty-fastacl",
   license = "2-clause BSD",
   maintainer = "qg.liu <lqglqy87@gmail.com>"
}
dependencies = {
   "lua >= 5.1",
   "lua-resty-etcd",
   "md5",
}
build = {
   type = "builtin",
   modules = {
      ["resty.fastacl"] = "lib/resty/fastacl.lua",
   }
}
