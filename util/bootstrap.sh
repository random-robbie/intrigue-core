#!/bin/bash

# if these are already set by our parent, use that.. otherwise sensible defaults
export "${INTRIGUE_DIRECTORY:=/core}"
export "${RUBY_VERSION:=2.5.1}"

#####
##### SYSTEM SETUP / CONFIG
#####

echo "[+] Preparing the System"

##### Add external repositories
# chrome repo
wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | sudo apt-key add -
echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" | sudo tee /etc/apt/sources.list.d/google-chrome.list
# postgres repo
sudo add-apt-repository "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -sc)-pgdg main"
wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -

##### Install postgres, redis
sudo apt-get -y update
sudo apt-get -y upgrade

sudo apt-get -y install apt-utils software-properties-common lsb-release sudo wget git-core bzip2 autoconf bison build-essential libssl-dev libyaml-dev libreadline6-dev zlib1g-dev libncurses5-dev libffi-dev libsqlite3-dev net-tools

##### Install postgres, redis
sudo apt-get -y install libpq-dev postgresql-9.6 postgresql-server-dev-9.6 redis-server boxes

##### Scanning
sudo apt-get -y install nmap zmap

##### Install masscan
if [ ! -f /usr/bin/masscan ]; then
  sudo apt-get -y install git gcc make libpcap-dev
  git clone https://github.com/robertdavidgraham/masscan
  cd masscan
  make
  sudo make install
fi

##### Java
sudo apt-get -y install default-jre

##### Install Thc-ipv6
sudo apt-get -y install thc-ipv6

##### Install headless chrome
sudo apt-get -y install libnss3
sudo apt-get -y install google-chrome-stable

# update sudoers
if ! sudo grep -q NMAP /etc/sudoers; then
  echo "[+] Configuring sudo for nmap, masscan"
  echo "Cmnd_Alias NMAP = /usr/local/bin/nmap" | sudo tee --append /etc/sudoers
  echo "Cmnd_Alias MASSCAN = /usr/local/bin/masscan" | sudo tee --append /etc/sudoers
  echo "%admin ALL=(root) NOPASSWD: NMAP, MASSCAN" | sudo tee --append /etc/sudoers
else
  echo "[+] nmap, masscan configured to run as sudo"
fi

# Set the database to trust
sudo sed -i 's/md5/trust/g' /etc/postgresql/9.6/main/pg_hba.conf
sudo service postgresql restart

echo "[+] Creating Database"
sudo -u postgres createuser intrigue
sudo -u postgres createdb intrigue_dev --owner intrigue

##### Install rbenv
if [ ! -d ~/.rbenv ]; then
  echo "[+] Configuring rbenv"
  git clone https://github.com/rbenv/rbenv.git ~/.rbenv
  cd ~/.rbenv && src/configure && make -C src
  echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bash_profile
  echo 'eval "$(rbenv init -)"' >> ~/.bash_profile
  source ~/.bash_profile
  # manually load it up... for docker
  eval "$(rbenv init -)"
  export PATH="$HOME/.rbenv/bin:$PATH"
  # ruby-build
  mkdir -p ~/.rbenv/plugins
  git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build
  # rbenv gemset
  git clone git://github.com/jf/rbenv-gemset.git ~/.rbenv/plugins/rbenv-gemset
else
  echo "[+] Upgrading rbenv"
  # upgrade rbenv
  cd ~/.rbenv && git pull
  # upgrade rbenv-root
  cd ~/.rbenv/plugins/ruby-build && git pull
  # upgrade rbenv-root
  cd ~/.rbenv/plugins/rbenv-gemset && git pull
fi

# setup ruby
if [ ! -e ~/.rbenv/versions/$RUBY_VERSION ]; then
  echo "[+] Installing Ruby $RUBY_VERSION"
  rbenv install $RUBY_VERSION
  export PATH="$HOME/.rbenv/versions/$RUBY_VERSION:$PATH"
else
  echo "[+] Using Ruby $RUBY_VERSION"
fi

rbenv global $RUBY_VERSION
echo "Ruby version: `ruby -v`"

# Install bundler
echo "[+] Installing Bundler"
gem install bundler --no-ri --no-rdoc
rbenv rehash

#####
##### INTRIGUE SETUP / CONFIGURATION
#####
echo "[+] Installing Gem Dependencies"
cd $INTRIGUE_DIRECTORY
bundle install

echo "[+] Running System Setup"
bundle exec rake setup

echo "[+] Running DB Migrations"
bundle exec rake db:migrate
bundle exec rake setup

echo "[+] Configuring puma to listen on 0.0.0.0"
sed -i "s/tcp:\/\/127.0.0.1:7777/tcp:\/\/0.0.0.0:7777/g" $INTRIGUE_DIRECTORY/config/puma.rb

echo "[+] Configuring puma to daemonize"
sed -i "s/daemonize false/daemonize true/g" $INTRIGUE_DIRECTORY/config/puma.rb

if [ ! -f /etc/init.d/intrigue ]; then
  echo "[+] Creating Intrigue system service"
  sudo cp $INTRIGUE_DIRECTORY/util/intrigue.service /lib/systemd/system
  sudo chmod +x $INTRIGUE_DIRECTORY/util/control.sh
fi

if ! $(grep -q instructions ~/.bash_profile); then
  echo "[+] Configurating..."
  echo "boxes -a c -d unicornthink $INTRIGUE_DIRECTORY/util/instructions" >> ~/.bash_profile
fi

# Docker Specifics!
# if we're running as root, we're probably in docker, so
#   manually force the .bash_profile to be run every login
if [ $(id -u) = 0 ]; then
   echo "source ~/.bash_profile" >> ~/.bashrc
fi

# run the service
$INTRIGUE_DIRECTORY/util/control.sh restart
