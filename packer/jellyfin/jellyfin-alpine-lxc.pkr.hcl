packer {
    required_plugins {
        lxc = {
            source  = "github.com/hashicorp/lxc"
            version = "~> 1"
        }
    }
}

source "lxc" "alpine" {
    config_file = "lxc.conf"
    template_name = "alpine-3.20-default"
    template_environment_vars = [""]
}

build {
    sources = [
        "source.lxc.alpine"
    ]
    provisioner "shell" {
        inline = [
            "setup-sshd -c openssh",
            "sudo apk update && sudo apk upgrade",
            "echo 'http://repo.jellyfin.org/alpine/latest' | sudo tee -a /etc/apk/repositories",
            "wget -O - https://repo.jellyfin.org/jellyfin_team.gpg.key | sudo tee /etc/apk/keys/jellyfin_team.rsa.pub >/dev/null",
            "sudo apk add jellyfin"
        ]
    }
}
