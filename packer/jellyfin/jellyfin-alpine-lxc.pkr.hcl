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
    create_options = ["--template", "download", "--", "--dist", "alpine", "--release", "3.20", "--arch", "x86_64"]
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
