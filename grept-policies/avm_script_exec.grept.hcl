data "http" "avm_script" {
  url = "${local.url_prefix}/avm"

  request_headers = merge({}, local.common_http_headers)
}

rule "file_hash" "avm_script" {
  glob = "avm"
  hash = sha1(data.http.avm_script.response_body)
}

fix "local_file" "avm_script" {
  rule_ids = [rule.file_hash.avm_script.id]
  paths    = ["avm"]
  content  = data.http.avm_script.response_body
  mode     = 755
}
