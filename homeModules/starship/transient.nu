# Keep right prompt on the status line so typing long commands on line 2 never collides with the clock.
$env.config.render_right_prompt_on_last_line = false

do --env {
    let ssh_host = (
        if ("SSH_CONNECTION" in $env) and ($env.SSH_CONNECTION | is-not-empty) {
            let raw = (sys host | get hostname)
            let short = (match $raw {
                "sarendia-orphanage" => "saren"
                "lucent-academy" => "lucent"
                "mercurius-foundation" => "mercurius"
                "twilight-caravan" => "twilight"
                "twinkle-wish" => "twinkle"
                _ => $raw
            })
            $" ($short) "
        } else {
            ""
        }
    )

    $env.TRANSIENT_PROMPT_INDICATOR = ""
    $env.TRANSIENT_PROMPT_COMMAND = {||
        let dir = (
            if $env.PWD == $nu.home-dir {
                "~"
            } else {
                let base = ($env.PWD | path basename)
                if ($base | is-empty) { "/" } else { $base }
            }
        )
        $"(ansi dark_gray)($ssh_host)($dir)(ansi reset) (ansi purple)❯(ansi reset) "
    }
    $env.TRANSIENT_PROMPT_COMMAND_RIGHT = {||
        $"(ansi dark_gray)(date now | format date '%H:%M:%S')(ansi reset)"
    }
}
