# WordPress on AWS with Varnish, nginx & MySQL
## What does it do?
This playbook provisions infrastructure in 3 different tiers. It can also teardown the infrastructure. It also contains vault encrypted secrets as an example of credential storage. *The playbook has been tested against Ubuntu 18.04 EC2 instances only.*

### Caching Tier
This tier consists of an ELB, with Varnish listening on an EC2 instance, which uses nginx as a proxy to pass requests to the private Web Tier ELB. The design decision of having both nginx and Varnish on this tier is that ELBs should always be referenced by their hostname as the underlying IP address is subject to change, and Varnish only evaluates the A record of the defined backend once. Comparitively, nginx will respect the TTL of the A record which can allow the ELB IP address to vary.

### Web Tier
The web tier is a very typical nginx + PHP 7.2 FPM setup. WP-CLI is installed to download and install WordPress.

### Data Tier
This is an RDS MySQL instance.

## Usage
To get started you will need to have your AWS credentials in an expected boto location, usually this is `~/.aws/credentials` but can be environment variable etc.  A normal format for `~/.aws/credentials` would be:
```
[default]
aws_secret_access_key = ACCESS_SECRET_HERE
aws_access_key_id = ACCESS_KEY_HERE
```

You will need to have a keypair already uploaded to EC2 in your desired region. It's important that your private key associated with this keypair is also loaded into your SSH agent or is the default so you will be prompted for password. You will also need to make sure you have created an [RDS Subnet Group](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/USER_VPC.WorkingWithRDSInstanceinaVPC.html#USER_VPC.CreateDBSubnetGroup) and that you know the name of it.

The following instructions are correct for running from an Ubuntu 18.04 machine as the Ansible initiator.
```
sudo apt-get install -y python-virtualenv
git clone https://github.com/peteruk08/wp-aws-fullstack-ansible.git
cd wp-aws-fullstack-ansible
virtualenv ansible
. ansible/bin/activate
pip install -r python-requirements.txt
ansible-vault decrypt vars/secrets.yml
```
The password for decryption is `test123`.

Use your favourite editor to edit `vars/secrets.yml` and customise as necessary.

Next, use your favourite editor to change `vars/config.yml`. Note that your keypair needs to be added per region, and that AMI IDs are also different across regions. You will need to provide subnet IDs for the instances to be launched into.

Once this is done, you can attempt to provision resources by running:
```
ansible-playbook -i local_inventory provision.yml
```
A URL will be provided as the last line in the playbook execution if everything went smoothly.

Best care has been taken to specifically target only our created resources using tagging, but it's still wise to be vigilant before running, but you can destroy resources with:
```
ansible-playbook -i local_inventory destroy.yml
```

## Limitations/Future Changes
While instances are launched behind ELBs they are not in ASGs nor are they scalable even if they were. The cache tier would be scalable once an AMI was made, although the actual cached data would not be shared among members of the pool.

The web tier is not stateless but could be made so quickly by using something like an EFS mount on the instances.

There is also currently no way to purge cache items from the Varnish cache, as neither the WordPress plugin necessary is installed, nor is the whitelisting setup correctly to allow it.
