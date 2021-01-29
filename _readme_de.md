## Warum der Proxy Stack?

1. SSL (`https://`) für alle lokalen Projekte.
1. Sprechende Namen, statt `localhost`.
1. Mehrere Projekte gleichzeitig bearbeiten (kein Blockieren von Port 80/443).
1. Einmaliges Setup + ein Kommando, um den Stack zu aktivieren. (einfach mit Bash Aliases
erweiterbar)
1. Eine Datenbank-Instanz für alle Datenbanken.
1. MySQL und PostgreSQL: Beides ist aktuell und verwendbar.
1. Administration: PhpMyAdmin für MySQL, wahlweise auch der Adminer für MySQL und Postgres.
1. Abfangen von E-Mails auf SMTP mit dem Mailcatcher.


## Installation

1. Projekt per Git mit `git clone ssh://git@gitlab.blawert.org:2204/misc/docker-compose.git` 
auf die eigene Maschine bringen.
1. Zertifikate auf der Maschine installieren:
   1. Für Firefox: `Einstellungen -> Dateschutz & Sicherheit -> Zertifikate anzeigen (ganz unten)`
   im Reiter `Zertifizierungsstellen` auf `Importieren`, dann zum `/certs` Ordner des Projekts
   navigieren und die `rootCA.pem` auswählen.
   1. Für Chrome: `Settings -> Manage certificates -> Authorities`, dann über Import zum `/certs` 
   Ordner des Projekts navigieren und die `rootCA.pem` auswählen.
1. Unter Linux `/etc/hosts` (unter Windows `C:\Windows\system32\drivers\etc\hosts`) aufrufen
und die Zeile `127.0.0.1 docker.test` hinzufügen. Für die Bearbeitung beider Dateien sind 
Root-Rechte notwendig.
1. Eine Kopie der `.env.dist` machen und als `.env` im selben Ordner abspeichern. 
Danach die Werte in der `.env` überprüfen. Der `SOCKET_PATH` ist auf Windows ein anderer.
Alle anderen Varialben können so bleiben.
1. Das Netzwerk anlegen: Die Variable `NETWORK_NAME` in der `.env` repräsentiert den Namen
des Docker-Netzwerks, in dem sich alle Container registrieren müssen. Mit 
`docker network create --attachable "{Name des Netswerks}"` muss dieses zuerst erstellt
werden. Dies ist eine einmalige Aktion. Der Name des Netzwerks sollte danach  nicht mehr
geändert werden.
   1. Testen, ob das Netzwerk vorhanden ist: `docker network ls` sollte eine Liste aller Netzwerke
   ausgeben. Das neue Netzwerk mit dem Namen hinter `NETWORK_NAME` sollte nun aufgelistet sein. 
1. Mit einer beliebigen Shell in den Ordner wechseln und `docker-compose up` ausführen.
Docker wird nun die benötigten Container herunterladen und dann starten.
1. Mit `docker ps -a` überprüfen, ob die Container mit dem Präfix `proxy-` den Status 
`Up ... Seconds` haben. Falls nicht, Schritt 4 wiederholen. Falls dann immer noch
nicht: Aufstehen, panisch im Kreis rennen und um Hilfe schreien!
1. Glückwunsch, Du hast den Proxy nun vollständig installiert! Er wird sich nun bei jedem 
Reboot Deiner Maschine einhängen und Dich nicht mehr in Ruhe lassen! \*muhahahahahha\*


## Projekte dem Proxy Netzwerk hinzufügen

1. Man wechsle mit einer beliebigen Shell in das Projektverzeichnis. (PhpStorm tut dies
automatisch, wenn ein neues Terminal aufgerufen wird.)
1. Erwartet wird eine `docker-compose.yml` (hier geht auch `.yaml`) Datei, die einen NGINX
sowie weitere beliebige Services enthält. Der NGINX braucht dabei folgende Konfiguration:
    ``` yaml
    nginx:
        image: nginx:latest # am besten eines von unseren Images
        container_name: ${CON_PREFIX}-web
        expose:
            - 80
            - 443
        volumes:
            - .:/var/www/html
        environment:
            # man wähle hier eine beliebige Subdomain von docker.test
            VIRTUAL_HOST: my-project.docker.test
            VIRTUAL_PORT: 443
            VIRTUAL_PROTO: https
    ```
    Der Platzhalter `my-project` sollte dabei durch einen ansprechenden, projektspezifischen 
    Namen ersetzt werden.
1. Das Netzwerk aus dem Docker-Proxy muss in der `docker-compose.yml` angegeben werden:
    ```yaml
    services:
       # ...
   
    networks:
        default:
            external:
                name: ${NETWORK_NAME}
    ```
1. Erwartet wird außerdem eine `.env` Datei, welche mindestens die Variable `CON_PREFIX` enthält
(siehe Punkt 2).
1. Hostnamen hinzufügen: Der als `VIRTUAL_HOST` gewählte Name der Domain muss noch in der 
Hosts-Datei der eigenen Maschine registriert werden. Das geschieht, wie oben, mit der IP 
`127.0.0.1`. Dies ist einmalig für jedes Projekt zu erledigen.
1. Man führe `docker-compose up -d` aus und teste unter dem angegebenen `VIRTUAL_HOST`, ob
man wieder schreiend im Kreis rennen muss.


## Docker-Proxy Update

1. Man steuere die Shell seiner Wahl in das Projektverzeichnis des Docker-Proxy.
1. Man tippe `git pull` und warte auf die Reaktion des entfernte Repositorys.
1. Man erkundinge sich über die Neuigkeiten in der readme.md und fahre fort mit der Nutzung,
wie gewohnt.


## E-Mail Catching

Unter https://mailcatcher.docker.test/ ist der Mailcatcher erreichbar. Dieser fängt alle per SMTP
gesendeten E-Mail auf und zeigt diese an.

Um dies mit **Symfony** zu erreichen, rennt man eine Runde schreiend im Kreis, dann stellt man die
DSN in der `.env` Datei auf `MAILER_DSN=smtp://mailcatcher:25` und erfreut sich seiner Kreationen
in Sachen hochmoderner E-Mail Kommunikation in formvollendeter Darstellung.

Für die Verwendung des Mailcatchers in **WordPress** verwenden wir ein Plugin. Was auch sonst.
Entweder installiert ihr WP Mail SMTP und verwendet dort "Other SMTP" mit dem "SMTP HOST" eingestellt 
auf `proxy-smtp`, dem "SMTP Port" auf `25` und deaktiviertem "Auto TLS" sowie deaktiviertem
"Authentication". Ihr könnt stattdessen auch ein eigenes Plugin mit folgender Datei einfügen:

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

Bei dem super creativ gewählt Namen "DockerExec" handelt es sich um eine Bash executable, welche
die Interaktion mit dem Docker-Proxy Stack vereinfacht, ja gar für jedes Kind nutzbar macht. Ob
dieses Wunderwerk der Softwarekunst unter Windows funktioniert, kann nur gemutmaßt werden, jedoch
erfreut sich ein jeder Linux-Entwickler der gewonnenen Simplizität.

**Vorteile zusätzlich zum Proxy Stack:**
1. Kürzere Befehle für Docker und Docker-Compose.
1. Zusätzliche Aufgaben, wie z.B. alle lokalen Container zu beenden oder Fragmente von Images
zu bereinigen.
1. Die `/etc/hosts` Datei auf dem Host-System wird automatisch aktualisiert.
1. Die `/etc/hosts` Dateien in den Container werden automatisch synchronisiert.
1. Bei Start eines Projekts werden die Domains ausgegeben &rarr; Klick öffnet Projekt im Browser.


### Installation des DockerExec

1. Auf einer beliebigen Shell die Executable aufrufen, z.B. `./path/to/DockerExec`.
1. Installationsanweisungen der Executable befolgen.


### Nutzung von DockerExec

1. Man nutzt es nicht, man lebt es!
1. Voraussetzung: Sind die Schritte 1 bis 3 von "Projekte dem Proxy Netzwerk hinzufügen" erfüllt
muss nichts weiter getan werden. Findige Entwickler haben in ihren Projekten bereits vorgesorgt. =)
1. Man versuche ein `DockerExec help` und erreiche ungeahntes Wissen & Erleuchtung!  
   ![Erleuchtung](https://media.giphy.com/media/Um3ljJl8jrnHy/giphy.gif)


### Einschränkungen von DockerExec

Einige Variablen sowie Konfigurationen sind an feste Namen gebunden und müssen manuell für ein
neues Projekt eingerichtet werden. Darüber hinaus ist eine Bash mindestvoraussetzung, da
`/bin/sh` nicht über genügend Synapsen verfügt, um die Genialität hinter DockerExec zu
verstehen.

1. Die Compose-Datei im Projektverzeichnis muss den namen `docker-compose.proxy.yml` (hier geht
auch `.yaml`) tragen.
   1. Je nach Umgebung gibt es auch die Dateien `docker-compose.prod.yml` oder (für
   alleinstehende Compose-Dateien) `docker-compose.yml`. Beide sind jedoch nicht für eine
   Testumgebung oder Entwicklerzwecke geeignet.
1. Es muss eine `.env` Datei im Projektverzeichnis existieren, die einige Variablen zwingend
angeben muss. Am besten man erstellt eine `.env.template` Datei, die im Projekt versioniert wird.


### Beispiel einer Mindestkonfiguration für PHP

Manche Environment Variablen können leider nicht aus der `.env` Datei gelesen werden und müssen
daher direkt für den Container unter `environment:` eingereiht werden. Hierzu gehört z.B. der
Domainname.

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
PHP_IMAGE=gitlab-registry.vcat.de/symfony/flex/php:7.4-fpm-dev
WEB_IMAGE=gitlab-registry.vcat.de/symfony/flex/nginx:latest
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
