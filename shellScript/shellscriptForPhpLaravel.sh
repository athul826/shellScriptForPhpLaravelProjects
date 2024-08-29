#!/bin/bash

# Step 1: Prompt for project details
read -p "Enter the name as the correct project name: " PROJECT_NAME
read -p "Enter the Git URL: " GIT_URL
read -p "Enter the Git branch name: " GIT_BRANCH
read -p "Enter the PHP version (e.g., 8.1): " PHP_VERSION
read -p "Enter the domain name for Nginx configuration: " DOMAIN_NAME

# Install Nginx
echo "Installing Nginx..."
sudo apt update
sudo apt install -y nginx

# Install PHP and Composer based on the PHP version
echo "Installing PHP $PHP_VERSION and Composer..."

# Update package list
sudo apt update

# Install PHP and required extensions based on PHP version
sudo apt install -y php$PHP_VERSION php$PHP_VERSION-cli php$PHP_VERSION-fpm php$PHP_VERSION-mysql php$PHP_VERSION-xml php$PHP_VERSION-mbstring php$PHP_VERSION-curl php$PHP_VERSION-intl php$PHP_VERSION-gd php$PHP_VERSION-zip

# Download and install Composer
if [ "$PHP_VERSION" == "8.1" ]; then
    COMPOSER_VERSION="2.3.7"
elif [ "$PHP_VERSION" == "8.0" ]; then
    COMPOSER_VERSION="2.2.8"
else
    echo "Composer version for PHP $PHP_VERSION is not predefined."
    echo "Please manually install Composer."
    exit 1
fi

echo "Installing Composer..."
curl -sS https://getcomposer.org/installer | php -- --version=$COMPOSER_VERSION
sudo mv composer.phar /usr/local/bin/composer

# Verify installations
echo "Verifying installations..."
php -v
composer -v
nginx -v

echo "Installation complete. Project details:"
echo "Project Name: $PROJECT_NAME"
echo "Git URL: $GIT_URL"
echo "Branch Name: $GIT_BRANCH"
echo "PHP Version: $PHP_VERSION"
echo "Domain Name: $DOMAIN_NAME"

# Step 2: Install and configure MySQL
echo "Installing MySQL..."
sudo apt update
sudo apt install -y mysql-server

echo "Starting MySQL service..."
sudo systemctl start mysql.service

# Prompt to customize the ALTER USER command
while true; do
    echo "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY 'password';"
    read -p "Do you want to edit this command? (y/n): " yn
    case $yn in
        [Yy]* ) 
            read -p "Enter the new MySQL root password: " MYSQL_ROOT_PASSWORD
            ALTER_COMMAND="ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$MYSQL_ROOT_PASSWORD';"
            echo "Executing: $ALTER_COMMAND"
            sudo mysql -e "$ALTER_COMMAND"
            break;;
        [Nn]* ) 
            MYSQL_ROOT_PASSWORD="password"
            ALTER_COMMAND="ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$MYSQL_ROOT_PASSWORD';"
            echo "Executing default command: $ALTER_COMMAND"
            sudo mysql -e "$ALTER_COMMAND"
            break;;
        * ) echo "Please answer yes or no.";;
    esac
done

# Confirm configuration success
while true; do
    read -p "MySQL root user configured successfully. Do you want to exit MySQL setup? (y/n): " yn
    case $yn in
        [Yy]* ) break;;
        [Nn]* ) echo "Returning to MySQL setup...";;
        * ) echo "Please answer yes or no.";;
    esac
done

# Test MySQL access
echo "Testing MySQL access..."
mysql -u root -p$MYSQL_ROOT_PASSWORD -e "SHOW DATABASES;" || { echo "Error: MySQL access test failed."; exit 1; }

# Provide access to MySQL prompt for further database creation
echo "You can now create a new database and use it."
mysql -u root -p$MYSQL_ROOT_PASSWORD || { echo "Error: Failed to access MySQL prompt."; exit 1; }

# Step 3: Fetch code from GitHub and set up project environment file
echo "Fetching code from GitHub..."
PROJECT_DIR="/var/www/html/$PROJECT_NAME"

# Check if the directory exists
if [ -d "$PROJECT_DIR" ]; then
    echo "Directory $PROJECT_DIR already exists."
    read -p "Do you want to remove the existing directory and clone a new repository? (y/n): " remove_yn
    if [ "$remove_yn" == "y" ]; then
        echo "Removing existing directory..."
        sudo rm -rf "$PROJECT_DIR"
    else
        echo "Aborting the script."
        exit 1
    fi
fi

# Clone the project repository
git clone -b "$GIT_BRANCH" "$GIT_URL" "$PROJECT_DIR" || { echo "Error: Failed to clone the repository."; exit 1; }

# Navigate to the project directory
cd "$PROJECT_DIR" || { echo "Error: Project directory $PROJECT_DIR does not exist."; exit 1; }

# Look for potential environment files and create .env
ENV_FILE_FOUND=false
for env_file in .env.example example.env env.example; do
    if [ -f "$env_file" ]; then
        echo "Creating .env file from $env_file..."
        cp "$env_file" .env
        ENV_FILE_FOUND=true
        break
    fi
done

if [ "$ENV_FILE_FOUND" = false ]; then
    echo "Error: No environment file (.env.example, example.env, or env.example) found. Please create a .env file manually."
    exit 1
fi

# Prompt to set up .env file credentials
while true; do
    read -p ".env file has been created. Do you want to set up .env file credentials? (y/n): " yn
    case $yn in
        [Yy]* ) 
            echo "Opening .env file for editing..."
            sudo vim .env
            break;;
        [Nn]* ) 
            echo "Skipping .env file setup. Make sure to configure it before proceeding."
            break;;
        * ) echo "Please answer yes or no.";;
    esac
done

# Composer install
echo "Running Composer install..."
composer install || { echo "Error: Composer install failed."; exit 1; }

# Set file permissions
echo "Setting file permissions..."
sudo chown -R www-data:www-data $PROJECT_DIR
sudo chmod -R 755 $PROJECT_DIR
sudo chmod -R 775 $PROJECT_DIR/storage
sudo chmod -R 775 $PROJECT_DIR/bootstrap/cache

# Generate application key
echo "Generating application key..."
sudo -u www-data php artisan key:generate || { echo "Error: Failed to generate application key."; exit 1; }

# Migrate the database
echo "Migrating the database..."
sudo -u www-data php artisan migrate || { echo "Error: Database migration failed."; exit 1; }

# Handle Nginx configuration files
echo "Handling Nginx configuration files..."

# Navigate to the Nginx sites-available directory
cd /etc/nginx/sites-available || { echo "Error: /etc/nginx/sites-available directory does not exist."; exit 1; }

# List all configuration files excluding default
EXISTING_FILES=$(ls | grep -v '^default$')

if [ -n "$EXISTING_FILES" ]; then
    echo "Found existing Nginx configuration files:"
    echo "$EXISTING_FILES"

    while true; do
        read -p "Do you want to remove existing configuration files? (y/n): " remove_yn
        case $remove_yn in
            [Yy]* )
                echo "Removing existing configuration files..."
                sudo rm -f $EXISTING_FILES
                break;;
            [Nn]* )
                echo "Skipping file removal."
                break;;
            * ) echo "Please answer yes or no.";;
        esac
    done
fi

# Create new configuration file
CONFIG_FILE="/etc/nginx/sites-available/$DOMAIN_NAME"
if [ -e "$CONFIG_FILE" ]; then
    read -p "Configuration file for $DOMAIN_NAME already exists. Do you want to overwrite it? (y/n): " overwrite_yn
    if [ "$overwrite_yn" == "y" ]; then
        echo "Overwriting $DOMAIN_NAME configuration file..."
    else
        echo "Skipping configuration file creation."
        exit 1
    fi
else
    echo "Creating new Nginx configuration file for $DOMAIN_NAME..."
fi

cat <<EOF | sudo tee $CONFIG_FILE
server {
    listen 80;
    server_name $DOMAIN_NAME;
    root /var/www/html/$PROJECT_NAME/public;

    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php$PHP_VERSION-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

echo "Linking the new configuration file..."
if [ -L "/etc/nginx/sites-enabled/$DOMAIN_NAME" ]; then
    echo "Symbolic link already exists. Removing old link..."
    sudo rm /etc/nginx/sites-enabled/$DOMAIN_NAME
fi

sudo ln -s $CONFIG_FILE /etc/nginx/sites-enabled/

# Test Nginx configuration
echo "Testing Nginx configuration..."
if sudo nginx -t; then
    echo "Nginx configuration is valid."
else
    echo "Error: Nginx configuration test failed. Please check your configuration files."
    exit 1
fi

# Restart Nginx
echo "Restarting Nginx..."
if sudo systemctl restart nginx; then
    echo "Nginx restarted successfully."
else
    echo "Error: Failed to restart Nginx. Please check Nginx service status."
    exit 1
fi
echo "Project has been deployed successfully. Go to your domain name to view the project."
