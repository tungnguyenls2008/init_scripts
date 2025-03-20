#!/usr/bin/env bash
# ini.sh - Initialize Dockerized Web App with:
#   - Frontend: Vue 3 + latest Node.js (configured to run on port 8080)
#   - Backend: Laravel 10 + PHP 8.3 (installed in backend/app, using MongoDB)
#   - MongoDB latest (with persistent volume)
#   - Mailpit for email testing
#   - Mongo Express for database management
# Uses Docker Compose and checks if services/projects already exist before creating them.

set -e

# Check for Docker
if ! command -v docker &> /dev/null; then
  echo "Docker is not installed or not in PATH. Please install Docker."
  exit 1
fi

# Check for Docker Compose (supports v2 and legacy)
if docker compose version &> /dev/null; then
  DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &> /dev/null; then
  DOCKER_COMPOSE="docker-compose"
else
  echo "Docker Compose is not installed. Please install Docker Compose."
  exit 1
fi

# Create necessary directories
mkdir -p backend/app
mkdir -p frontend

# 1. Create docker-compose.yml if it doesn't exist
if [ ! -f "docker-compose.yml" ]; then
  echo "Generating docker-compose.yml..."
  cat > docker-compose.yml <<'EOF'
version: "3.9"

services:
  # Frontend service (Vue 3 + Node.js)
  frontend:
    image: node:latest
    working_dir: /app
    volumes:
      - ./frontend:/app
    ports:
      - "8080:8080"
    # Explicitly run dev server on port 8080
    command: ["npm", "run", "dev", "--", "--host", "0.0.0.0", "--port", "8080"]
    depends_on:
      - backend

  # Backend service (Laravel 10 with PHP 8.3)
  backend:
    build:
      context: ./backend
      dockerfile: Dockerfile
    working_dir: /var/www/html
    volumes:
      - ./backend/app:/var/www/html
    ports:
      - "8000:8000"
    environment:
      - APP_PORT=8000
      - DB_CONNECTION=mongodb
      - DB_HOST=mongodb
      - DB_PORT=27017
      - DB_DATABASE=laravel
      - DB_USERNAME=root
      - DB_PASSWORD=root
      - MAIL_MAILER=smtp
      - MAIL_HOST=mailpit
      - MAIL_PORT=1025
      - MAIL_USERNAME=null
      - MAIL_PASSWORD=null
      - MAIL_ENCRYPTION=null
    depends_on:
      - mongodb
    command: ["php", "artisan", "serve", "--host=0.0.0.0", "--port=8000"]

  # MongoDB service
  mongodb:
    image: mongo:latest
    ports:
      - "27017:27017"
    volumes:
      - mongodb_data:/data/db
    environment:
      - MONGO_INITDB_ROOT_USERNAME=root
      - MONGO_INITDB_ROOT_PASSWORD=root
      - MONGO_INITDB_DATABASE=laravel

  # Mongo Express service
  mongo-express:
    image: mongo-express:latest
    depends_on:
      - mongodb
    ports:
      - "8081:8081"
    environment:
      - ME_CONFIG_MONGODB_ADMINUSERNAME=root
      - ME_CONFIG_MONGODB_ADMINPASSWORD=root
      - ME_CONFIG_MONGODB_URL=mongodb://root:root@mongodb:27017/laravel?authSource=admin

  # Mailpit service (SMTP mail catcher)
  mailpit:
    image: axllent/mailpit:latest
    ports:
      - "8025:8025"
      - "1025:1025"

volumes:
  mongodb_data:
EOF
else
  echo "docker-compose.yml already exists. Skipping creation."
fi

# 2. Create Dockerfile for backend if it doesn't exist
if [ ! -f "backend/Dockerfile" ]; then
  echo "Creating backend/Dockerfile..."
  cat > backend/Dockerfile <<'EOF'
FROM php:8.3-cli

RUN apt-get update && apt-get install -y \
    git curl zip unzip \
    libzip-dev libpq-dev libpng-dev libonig-dev \
    && docker-php-ext-install pdo_mysql zip \
    # Install mongodb extension
    && pecl install mongodb \
    && docker-php-ext-enable mongodb \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/html
EOF
else
  echo "backend/Dockerfile already exists. Skipping creation."
fi

# 3. Build the Laravel backend image
echo "Building Laravel backend image..."
$DOCKER_COMPOSE build backend

# 4. Initialize Laravel project if it hasn't been created in backend/app
if [ ! -f "backend/app/composer.json" ]; then
  echo "Initializing new Laravel 10 project in backend/app..."
  $DOCKER_COMPOSE run --rm backend composer create-project laravel/laravel .

  echo "Configuring Laravel environment for MongoDB..."
  $DOCKER_COMPOSE run --rm backend cp .env.example .env
  # Update .env for MongoDB connection
  sed -i "s/DB_CONNECTION=.*/DB_CONNECTION=mongodb/" backend/app/.env
  sed -i "s/DB_HOST=.*/DB_HOST=mongodb/" backend/app/.env
  sed -i "s/DB_PORT=.*/DB_PORT=27017/" backend/app/.env
  sed -i "s/DB_DATABASE=.*/DB_DATABASE=laravel/" backend/app/.env
  sed -i "s/DB_USERNAME=.*/DB_USERNAME=root/" backend/app/.env
  sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=root/" backend/app/.env
  sed -i "s/MAIL_HOST=.*/MAIL_HOST=mailpit/" backend/app/.env
  sed -i "s/MAIL_PORT=.*/MAIL_PORT=1025/" backend/app/.env

  echo "Generating Laravel application key..."
  $DOCKER_COMPOSE run --rm backend php artisan key:generate

  echo "Installing MongoDB driver for Laravel (mongodb/laravel-mongodb)..."
  $DOCKER_COMPOSE run --rm backend composer require mongodb/laravel-mongodb

  # You might need to adjust Laravel's config/database.php to use the mongodb connection
  echo "Consider updating config/database.php to set the default connection to mongodb."
  echo "Also, ensure your Laravel models extend Mongodb\Eloquent\Model."

  # Configure database.php for MongoDB
  echo "Configuring config/database.php for MongoDB..."
  $DOCKER_COMPOSE run --rm backend sed -i "s/'default' => env('DB_CONNECTION', 'sqlite'),/'default' => env('DB_CONNECTION', 'mongodb'),/" config/database.php
  $DOCKER_COMPOSE run --rm backend sed -i "/'connections' => \[/a\
              'mongodb' => [\
                  'driver' => 'mongodb',\
                  'host' => env('DB_HOST', 'mongodb'),\
                  'port' => env('DB_PORT', 27017),\
                  'database' => env('DB_DATABASE', 'laravel'),\
                  'username' => env('DB_USERNAME', 'root'),\
                  'password' => env('DB_PASSWORD', 'root'),\
                  'options' => [\
                      'app_name' => 'laravel',\
                  ],\
              ]," config/database.php

else
  echo "Laravel project already exists in backend/app. Skipping Laravel installation."
  if [ -f "backend/app/.env" ]; then
    echo "Updating Laravel .env with Docker and MongoDB settings..."
    sed -i "s/DB_CONNECTION=.*/DB_CONNECTION=mongodb/" backend/app/.env || true
    sed -i "s/DB_HOST=.*/DB_HOST=mongodb/" backend/app/.env || true
    sed -i "s/DB_PORT=.*/DB_PORT=27017/" backend/app/.env || true
    sed -i "s/DB_DATABASE=.*/DB_DATABASE=laravel/" backend/app/.env || true
    sed -i "s/DB_USERNAME=.*/DB_USERNAME=root/" backend/app/.env || true
    sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=root/" backend/app/.env || true
    sed -i "s/MAIL_HOST=.*/MAIL_HOST=mailpit/" backend/app/.env || true
    sed -i "s/MAIL_PORT=.*/MAIL_PORT=1025/" backend/app/.env || true
  fi
  if [ -f "backend/app/composer.json" ] && [ ! -d "backend/app/vendor" ]; then
    echo "Installing Laravel dependencies..."
    $DOCKER_COMPOSE run --rm backend composer install
  fi
fi

# 5. Initialize Vue 3 project if not already set up
if [ ! -f "frontend/package.json" ]; then
  echo "Initializing new Vue 3 project in frontend..."
  $DOCKER_COMPOSE run --rm frontend npm create vite@latest . -- --template vue

  echo "Creating Vue .env file..."
  cat > frontend/.env <<EOL
VITE_API_URL=http://localhost:8000
EOL
else
  echo "Vue project already exists. Skipping Vue initialization."
fi

# Install Node dependencies for Vue
if [ -f "frontend/package.json" ]; then
  echo "Installing Vue dependencies..."
  $DOCKER_COMPOSE run --rm frontend npm install
fi

# 6. Start all services using Docker Compose
echo "Starting Docker services..."
$DOCKER_COMPOSE up -d

# 7. Adjust file ownership for backend/app and frontend directories to the current user
#    This ensures files created by the containers (often as root) are reassigned to your user.
echo "Adjusting file ownership to the current user..."
sudo chown -R $(id -u):$(id -g) *
sudo chown -R $(id -u):$(id -g) frontend/node_modules/*

echo "Setup complete!"
echo "- Vue Frontend: http://localhost:8080"
echo "- Laravel Backend: http://localhost:8000"
echo "- MongoDB: mongodb://localhost:27017 (User: root, Password: root, Database: laravel, Auth Source: admin)"
echo "- Mongo Express: http://localhost:8081 (User: admin, Password: pass)"
echo "- Mailpit: http://localhost:8025 (SMTP on port 1025)"
echo "To stop services, run: $DOCKER_COMPOSE down"
