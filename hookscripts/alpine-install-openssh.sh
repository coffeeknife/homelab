#!/usr/bin/ash

# Exmple hook script for PVE guests (hookscript config option)
# You can set this via pct/qm with
# pct set <vmid> -hookscript <volume-id>
# qm set <vmid> -hookscript <volume-id>
# where <volume-id> has to be an executable file in the snippets folder
# of any storage with directories e.g.:
# qm set 100 -hookscript local:snippets/hookscript.pl

echo "GUEST HOOK: $@"

# First argument is the vmid

vmid = $1;

# Second argument is the phase

phase = $2;

if [phase -eq 'pre-start']; then 

    # First phase 'pre-start' will be executed before the guest
    # is started. Exiting with a code != 0 will abort the start

    # print "preparations failed, aborting."

elif [phase -eq 'post-start']; then

    # Second phase 'post-start' will be executed after the guest
    # successfully started.

    setup-sshd -c openssh
    echo "$vmid started successfully."

elif [phase -eq 'pre-stop']; then

    # Third phase 'pre-stop' will be executed before stopping the guest
    # via the API. Will not be executed if the guest is stopped from
    # within e.g., with a 'poweroff'

elif [phase -eq 'post-stop']; then

    # Last phase 'post-stop' will be executed after the guest stopped.
    # This should even be executed in case the guest crashes or stopped
    # unexpectedly.

else 
    echo "got unknown phase '$phase'" 1>&2; exit 1
fi

exit 0
