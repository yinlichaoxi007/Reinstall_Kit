# 本机私有配置模板
# 复制为 local.config.ps1 后填写本机实际值；local.config.ps1 已被 .gitignore 排除
# 留空时脚本回退到环境变量：用户名用 $env:USERNAME，机器名用 $env:COMPUTERNAME，
# 迁移根目录用 D:\migration\C\Users\<用户名>

$LocalUserName     = ''
$LocalComputerName = ''
$MigrationRoot     = ''
