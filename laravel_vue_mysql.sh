#!/usr/bin/env bash
# ini.sh - Initialize Dockerized Web App with:
#   - Frontend: Vue 3 + latest Node.js (configured to run on port 8080)
#   - Backend: Laravel 10 + PHP 8.3 (installed in backend/app, using MySQL)
#   - MySQL 8 (with persistent volume)
#   - Mailpit for email testing
#   - phpMyAdmin for database management
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
      - DB_CONNECTION=mysql
      - DB_HOST=mysql
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
      - mysql
    command: ["php", "artisan", "serve", "--host=0.0.0.0", "--port=8000"]

  # MySQL service
  mysql:
    image: mysql:8
    ports:
      - "3306:3306"
    volumes:
      - db_data:/var/lib/mysql
    environment:
      - MYSQL_ROOT_PASSWORD=root
      - MYSQL_DATABASE=laravel
      - MYSQL_USER=laravel
      - MYSQL_PASSWORD=laravel

  # phpMyAdmin service
  phpmyadmin:
    image: phpmyadmin:latest
    depends_on:
      - mysql
    environment:
      - PMA_HOST=mysql
      - PMA_USER=root
      - PMA_PASSWORD=root
    ports:
      - "8081:80"

  # Mailpit service (SMTP mail catcher)
  mailpit:
    image: axllent/mailpit:latest
    ports:
      - "8025:8025"
      - "1025:1025"

volumes:
  db_data:
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

  echo "Configuring Laravel environment..."
  $DOCKER_COMPOSE run --rm backend cp .env.example .env
  # Update .env for MySQL connection
  sed -i "s/DB_CONNECTION=.*/DB_CONNECTION=mysql/" backend/app/.env
  sed -i "s/DB_HOST=.*/DB_HOST=mysql/" backend/app/.env
  sed -i "s/DB_DATABASE=.*/DB_DATABASE=laravel/" backend/app/.env
  sed -i "s/DB_USERNAME=.*/DB_USERNAME=root/" backend/app/.env
  sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=root/" backend/app/.env
  sed -i "s/MAIL_HOST=.*/MAIL_HOST=mailpit/" backend/app/.env
  sed -i "s/MAIL_PORT=.*/MAIL_PORT=1025/" backend/app/.env

  echo "Generating Laravel application key..."
  $DOCKER_COMPOSE run --rm backend php artisan key:generate

  echo "Running migrations to create necessary tables..."
  $DOCKER_COMPOSE run --rm backend php artisan migrate --force
else
  echo "Laravel project already exists in backend/app. Skipping Laravel installation."
  if [ -f "backend/app/.env" ]; then
    echo "Updating Laravel .env with Docker settings..."
    sed -i "s/DB_CONNECTION=.*/DB_CONNECTION=mysql/" backend/app/.env || true
    sed -i "s/DB_HOST=.*/DB_HOST=mysql/" backend/app/.env || true
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
echo "- MySQL: localhost:3306 (User: root, Password: root, Database: laravel)"
echo "- phpMyAdmin: http://localhost:8081"
echo "- Mailpit: http://localhost:8025 (SMTP on port 1025)"
echo "To stop services, run: $DOCKER_COMPOSE down"
