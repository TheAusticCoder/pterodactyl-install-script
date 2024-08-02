#!/bin/bash

set -e

# Function to check the success of each command
check_command() {
    "$@"
    if [ $? -ne 0 ]; then
        echo "Error: Command failed - $@"
        exit 1
    fi
}

# Prompt user for MariaDB root password
read -sp 'Enter MariaDB root password: ' mariadb_root_password
echo
read -sp 'Confirm MariaDB root password: ' mariadb_root_password_confirm
echo

if [ "$mariadb_root_password" != "$mariadb_root_password_confirm" ]; then
    echo "Passwords do not match. Exiting."
    exit 1
fi

# Prompt user for Pterodactyl database user password
read -sp 'Enter Pterodactyl database user password: ' pterodactyl_db_password
echo
read -sp 'Confirm Pterodactyl database user password: ' pterodactyl_db_password_confirm
echo

if [ "$pterodactyl_db_password" != "$pterodactyl_db_password_confirm" ]; then
    echo "Passwords do not match. Exiting."
    exit 1
fi

# Update package list and install dependencies
check_command apt -y update
check_command apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg

# Add repositories for PHP, Redis, and MariaDB
check_command LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
check_command curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
check_command echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/redis.list
check_command curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash

# Update repositories list
check_command apt update

# Install required packages
check_command apt -y install php8.1 php8.1-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} mariadb-server nginx tar unzip git redis-server

# Secure MariaDB installation
check_command mysql -e "UPDATE mysql.user SET Password = PASSWORD('$mariadb_root_password') WHERE User = 'root'"
check_command mysql -e "DELETE FROM mysql.user WHERE User=''"
check_command mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1')"
check_command mysql -e "DROP DATABASE IF EXISTS test"
check_command mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%'"
check_command mysql -e "FLUSH PRIVILEGES"

# Install Composer
check_command curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# Set up Pterodactyl panel
check_command mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
check_command curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
check_command tar -xzvf panel.tar.gz
check_command chmod -R 755 storage/* bootstrap/cache/
check_command cp .env.example .env

# Install Composer dependencies
check_command composer install --no-dev --optimize-autoloader

# Generate application key
check_command php artisan key:generate --force

# Set up environment configuration
check_command php artisan p:environment:setup

# Set up database configuration
check_command php artisan p:environment:database

# Set up mail configuration
check_command php artisan p:environment:mail

# Create a database and user for Pterodactyl
check_command mysql -u root -p"$mariadb_root_password" -e "CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$pterodactyl_db_password';"
check_command mysql -u root -p"$mariadb_root_password" -e "CREATE DATABASE panel;"
check_command mysql -u root -p"$mariadb_root_password" -e "GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;"
check_command mysql -u root -p"$mariadb_root_password" -e "FLUSH PRIVILEGES;"

# Run database migrations and seed data
check_command php artisan migrate --seed --force

# Create the first administrative user
check_command php artisan p:user:make

# Set permissions for web server
check_command chown -R www-data:www-data /var/www/pterodactyl/*

# Create and enable Pterodactyl Queue Worker service
cat <<EOT > /etc/systemd/system/pteroq.service
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOT

check_command systemctl enable --now redis-server
check_command systemctl enable --now pteroq.service

# Set up cron job for Pterodactyl tasks
(crontab -l ; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") | crontab -

echo "Pterodactyl installation completed successfully!"
