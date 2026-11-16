# Nushell Environment Config File

const extra_config = $nu.default-config-dir | path join 'config.local.nu'
if not ($extra_config | path exists) {
    touch $extra_config
}
