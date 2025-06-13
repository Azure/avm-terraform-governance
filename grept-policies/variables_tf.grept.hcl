rule "must_be_true" "variable_tf_should_not_exist" {
  condition     = !fileexists("variable.tf")
  error_message = "file name should be `variables.tf` rather than `variable.tf`."
}

fix "rename_file" "variable_tf_to_variables_tf" {
  rule_ids = [rule.must_be_true.variable_tf_should_not_exist.id]
  old_name = "variable.tf"
  new_name = "variables.tf"
}