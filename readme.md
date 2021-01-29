## What is the Docker-Proxy-Stack?

The docker proxy stack is primarily a toolkit for local web development that
supports

1. SSL (`https://`) for all local projects.
1. descriptive names instead of `localhost`.
1. running multiple projects at the same time
   - sharing database containers (MySQL & PostgreSQL)
   - sharing certificates
   - sharing a mailcatcher
   - sharing a reverse proxy
     (thus not blocking port 80/443)
1. easy initial setup
1. DB administration with PhpMyAdmin and Adminer
1. catching E-Mails via SMTP with mailcatcher

### So why do we do all this?

If you are running multiple web applications on one machine at the same time 
you are running into a couple of issues.  
If your projects are already dockerized, every `docker-compose` file will

- run their own webserver
- run their own database
- use probaby the same port for each of those.

You also have to manage SSL certificates for each project.

The solution the Docker proxy stack provides is taking care of all shared
ressources. So

- run a reverse proxy to manage all projects web-servers
- run one database server
- provide a custom certificate
- run DBA tools like PMA or Adminer
- run a mailcatcher
- and set all of it up in a conveniant way with `DockerExec`.



## Installation

1. Install Docker and Docker Compose.
1. Clone the repository.
1. Configure and create a root certificate
   - run `DockerExec create-cert` and follow the prompts. This should create a
   `certs` folder containing mkcert root certificates and the mkcert key and
   certificate.
1. Install the certificates on your dev machine:
   - **Firefox:** `Settings -> Security -> Show Certificates`  
     In the tab `certificate authorities` click `import`, navigate to the
     aforementioned `/certs` folder and select `rootCA.pem` to import.
   - **Chrome:** In `Settings -> Manage certificates -> Authorities` import the 
   `rootCA.pem` from the `/certs` folder.  
1. As root, edit your `hosts` file
   - Linux: `/etc/hosts`
   - Windows: `C:\Windows\system32\drivers\etc\hosts`  
   to contain the line  
   `127.0.0.1 docker.test`
1. Copy over the file `.env.dist` to `.env` in the same folder and verify all 
   values in `.env` to be to your requirements.  
   (Windows uses a different `SOCKET_PATH` -- all other variables should be
   fine.)
1. Create the Docker network:  
   The variable `NETWORK_NAME` in `.env` represents that network name all 
   containers in this stack have to register in.  
   Use `docker network create --attachable "{YOUR_NETWORK_NAME}"` once to create
   the network. Don't change it afterwards.
   - You can now test if the network was created.  
     `docker network ls` should print a list of all networks including `YOUR_NETWORK_NAME`
1. Inside the repository run `docker-compose up`.  
   Docker will now download all necessary containers and run them.
1. You can check if it all works with `docker ps -a`.  
   All containers with the prefix `proxy-` should have the status `Up ... Seconds`.


## How to add Projects to the Docker Proxy Network

The main goal here is to add multiple projects, that are dockerized, to the same
proxy network

1. `DockerExec` expects a `docker-compose.y(a)ml` file that contains nginx and all 
   other services you might need for your project (sans DB / BDA tool)  
   Configure nginx like this:
    ``` yaml
    nginx:
        image: nginx:latest
        container_name: ${CON_PREFIX}-web
        expose:
            - 80
            - 443
        volumes:
            - .:/var/www/html environment: # choose a docker.test subdomain
        VIRTUAL_HOST: my-project.docker.test VIRTUAL_PORT: 443 VIRTUAL_PROTO:
        https ``` `my-project` should be your project name.
1. Specify the Docker network you created above in `docker-compose.yml`:
    ```yaml
    services:
       # ...
   
    networks:
        default:
            external:
                name: ${NETWORK_NAME}
    ```
1. You also need a `.env` file to specify at least `CON_PREFIX`
1. Add a hostname specific to your project: `VIRTUAL_HOST` has to be added to you hosts file.  
   Add the following line once for every project:  
   `127.0.0.1 VIRTUAL_HOST`
1. Try it out:  
   Run `docker-compose up -d` and in your browser of choice browse to `VIRTUAL_HOST`


## Docker-Proxy-Stack Update

In the root directory of this repository 

1. run `git pull`
1. read new release notes
1. follow instructions in this `readme.md`


## E-Mail Catching

Part of this stack is the Mailcatcher which catches all mails sent via SMTP. The
mailcatcher runs at `https://mailcatcher.docker.test/`

Current use-cases include mails sent by **Symfony** and **WordPress**.

### Symfony

In your projects `.env` file set `MAILER_DSN=smtp://mailcatcher:25`. That's it.

### WordPress

Two options:

1. Install the Plugin **WP Mail SMTP**, use the option "Other SMTP" and set the
   variable "SMTP HOST" to `proxy-smtp` and "SMTP Port" to `25`, deactivate
   "Auto TLS", deactivate "Authentication".
1. Create your own plugin with this code snippet:

```php
<?php
/**
 * Proxy SMTP Adapter
 *
 * @package nginx-proxy
 * @license GPLv3
 *
 * @wordpress-plugin
 * Plugin Name: Proxy SMTP Adapter
 * Description: Configure WordPress to send emails to the Mailcatcher available at the host name "proxy-smtp"
 * Version: 1.0.0
 * Text Domain: nginx-proxy
 * License: GPLv3
 * License URI: http://www.gnu.org/licenses/gpl-3.0.txt
 */

/**
 * Configure WordPress to send emails to the Mailcatcher available at the host name "proxy-smtp".
 *
 * @param PHPMailer $phpmailer The PHPMailer instance.
 */
function proxy_smtp_config( $phpmailer ) {
	$phpmailer->isSMTP();
	$phpmailer->Host     = 'proxy-smtp';
	$phpmailer->SMTPAuth = false;
	$phpmailer->Port     = 25;
}
add_action( 'phpmailer_init', 'proxy_smtp_config' );

```


## DockerExec

To simplify most of the aforementioned tasks and add additional functionality
for usual interactions with the Docker-Proxy-Stack, we provice the Bash script
`DockerExec`.

### Additional Advantages

1. Concise commands for Docker and Docker-Compose.
1. Perform additional tasks like stopping all local Docker containers or remove
   images.
1. Update local `/etc/hosts` automatically.
1. Synchronize the containers `/etc/hosts` files automatically.
1. Starting up a project will print the projects domain to your command line.


### How to install DockerExec?

1. Run the script with `./path/to/DockerExec`.
1. Follow the instructions provided by `DockerExec`.


### How to use DockerExec?

1. If you already setup step 1 - 3 of "How to add Projects to the Docker Proxy
   Network" you are all set.
1. Try and follow `DockerExec help`.

### Limitations of DockerExec

At this point some variables and configuration are hard coded and have to be 
set manually for a new project.  
You also need Bash. `/bin/sh` will not suffice.

1. Your projects Docker-Compose file has to have the name
   `docker-compose.proxy.y(a)ml`.
   - Depending on your environment there can also be a
     `docker-compose.prod.y(a)ml` or for a single Compose file
     `docker-compose.y(a)ml`. These are not suited for local dev environments.
1. You have to provide a `.env` file in your project root to set necessary
   variables. A best practice would be to have a version-controlled
   `.env.template` which you copy over to `.env` and customize on deployment.


### A Minimal Configuration for PHP

Some environment variables cannot be read from the `.env` file and have to be manually added to the container under `environment`. E.g. the domain name.


```yaml
# docker-compose.proxy.yml
version: '3.5'

services:
    web:
        image: ${WEB_IMAGE}
        container_name: ${CON_PREFIX}-web
        env_file: .env
        volumes:
            - .:/var/www/html
        expose:
            - 80
            - 443
        environment:
            VIRTUAL_HOST: my-project.docker.test
            VIRTUAL_PORT: 443
            VIRTUAL_PROTO: https
        links:
            - php

    php:
        image: ${PHP_IMAGE}
        container_name: ${CON_PREFIX}-app
        env_file: .env
        volumes:
            - .:/var/www/html

networks:
    default:
        external:
            name: ${NETWORK}
```

```
# .env

# on a Windows machine
# convert windows path to linux in docker-compose
COMPOSE_CONVERT_WINDOWS_PATHS=1

# docker-compose configuration
CON_PREFIX=project # prefix name for the running docker container
PHP_IMAGE={$CONTAINER_REGISTRY}/symfony/flex/php:7.4-fpm-dev
WEB_IMAGE={$CONTAINER_REGISTRY}/symfony/flex/nginx:latest
NETWORK=nginx-proxy

### specific to your project
# MySQL configuration
MYSQL_HOST=proxy-db
MYSQL_PORT=3306
MYSQL_USER=root
MYSQL_DATABASE=my_project_db
MYSQL_ROOT_PASSWORD=root

# or PostgreSQL configuration
POSTGRES_HOST=proxy-pg
POSTGRES_PORT=5432
POSTGRES_USER=root
POSTGRES_DB=my_project_db
POSTGRES_PASSWORD=root
```

## ToDos

Although the Docker-Proxy-Stack is fully functional, there is a lot of potential for further development.

- documentation
  - try all steps on a fresh system and verify the instructions
  - add screenshots
- DockerExec
  - add common tasks
  - rewrite in Python
  - make functionality more discoverable
