# HPC Usage Notes
General user documentation can be found here: [https://centers.hpc.mil/users/index.html](https://centers.hpc.mil/users/index.html). Refer to this document for any details.

## User Onboarding
Users for the HPC are required to be citizens of the USA. Contact John Alora to begin the process. *The goal of this is to obtain the all-powerful Yubikey to access the cluster!*

The general steps should include:

### Complete cyber awareness training
1. Go to this link: https://www.cyber.mil/cyber-awareness-challenge
    1. Complete the training and then save the pdf. You'll need this for later.

After you've completed cyber awareness training, you can set up a DoD HPC Account:
1. Go here: https://ieapp.hpc.mil/info/login/pieLogin and click "Apply for pIE Account" -> "Request login without CAC"
2. Fill out New User Account:
    1. Preferred Kerberos Realm: HPCMP.HPC.MIL
    2. Select org: OUSAF (Other USAF)
    3. Company/Org: Stanford University / AI Studio
    4. Business/School Address: 496 Lomita Mall, Stanford, CA 94305
    5. email address: Stanford email address
    6. US Government employee: No
        1. Email address: john.alora.1@us.af.mil
    7. Add a new comment to this user: Stanford University (Civilian Institute) / Major John Alora (Sponsor) / AI Studio / Request Yubi Key / "Put address where you want the Yubi key shipped"
3. Once complete, let John know! He'll connect you to the Agency Approval Authority (AAA). You'll send your cyber awareness training certificate to the AAA.

### Background check
Go to the UPS and request for an **ink print**. This should be a small card that does not have a ton of numbers to fill out. The ERDC point of contact (should be Judy) will send you the instructions.

>[!IMPORTANT]
>On the fingerprint card on the left-hand side, under "REASON FINGERPRINTED": You will be required to document our Security Codes for processing:
> **SOI: Z256, SON: 2222, ALC: 21008711**
>
>**Note:**
> If you do not document the security codes on your fingerprint card, the PSI Fingerprint Team will "discard" your card.

Send your tracking number to the ERDC point of contact to begin the background check.

## Setup
The following steps required to set up the environment for using the HPC system.

### Installing Kerberos
Download and install Kerberos software at: [https://centers.hpc.mil/users/index.html#kerberos](https://centers.hpc.mil/users/index.html#kerberos).

To install:
 - Principle: [Your username]
 - Password: [should be sent to your email]
 - Realm: `HPCMP.HPC.MIL`

Download for your operating system. Check that your installation is correct and obtain a Kerberos ticket:
```bash
kshell    # Initialize your shell
kinit     # Initialize your session
klist     # View your tickets
```
These are valid for 10 hours.

>[!TIP]
You have the option to change your password within 20 days. To do so, type the following after obtaining a Kerberos ticket, and follow the prompts to change your password:
```bash
kshell    # Initialize your shell
kpasswd   # Change pw
```

>[!TIP]
If `kinit` is finding the wrong username, you can manually specify your principle:
```bash
kinit [username]@HPCMP.HPC.MIL
```

>[!WARNING]
Kerberos initialization changes the ordering of which your authentication certificates are handled. Run `chmod 600 ~/.ssh/config` if there is a permissions issue. A few workarounds for handling ssh-id's vs kerberos id's to change your ssh-config to include the following:
```bash
IdentitiesOnly yes
GSSAPIAuthentication no
PreferredAuthentications publickey
```

### Authenticate to the HPC Portal
The HPC Portal provides you with GUI tools on their (incredibly outdated looking) web interface. Some useful tools include the ability to check node availability and ability to manage files and jobs.

To load, navigate your browser to: [https://centers.hpc.mil/portal](https://centers.hpc.mil/portal).

## Cluster Basics
Introduce the basic concepts and structure of the HPC cluster.

### SSH Configurations
Depending on how you set up your ssh-config, you might want to add in the following, to force usage of GSS-API authentication:
```bash
Host *.arl.hpc.mil *.hpc.mil
  GSSAPIAuthentication yes
  GSSAPIDelegateCredentials yes
  PreferredAuthentications gssapi-with-mic,publickey
  User [username]
```

As before, ensure that you are logged into a Kerberos shell:
```bash
kshell    # Initialize your shell
kinit     # Initialize your session
```

For any of the clusters, simply ssh in via your Kerberos certificate (enabled with GSS-API): `ssh [user]@[cluster.system]`. The following are available for us to use at the August 2025:

| System    | Login                     | Center |
|-----------|---------------------------|--------|
| Jean      | jean.arl.hpc.mil          | ARL    |
| Nautilus  | nautilus.navydsrc.hpc.mil | NAVY   |
| Raider    | raider.afrl.hpc.mil       | AFRL   |
| Wheat     | wheat.erdc.hpc.mil        | ERDC   |


## Running Jobs
Detail the process of submitting and managing jobs on the HPC system. Unfortunately, each of the clusters have specific commands required to run any jobs (including keywords, etc.) as of August 2025.

### Raider
**Notes:** Infiniband connection, has NCCL backend.

#### Interactive Job
Good for debugging! 
```bash
srun --account ousaf40080AIR -q hie --nodes 1 --gpus-per-node 1 --ntasks-per-node=1 --constraint=mla --time=60:00 --pty bash
```

### Jean

### Nautilus

### Wheat
