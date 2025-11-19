# 🚀 Enterprise Linux Backup Automation System

A clean and automated Linux backup solution designed for reliability, security, and easy deployment.

## 📌 Features
- 🔒 Secure SSH key-based backup transfers
- 🤖 Fully automated with cron scheduling
- 📱 Discord notification support
- 📊 CSV reporting & audit logs
- 🔄 Restore system for disaster recovery
- 🧹 Automatic retention cleanup

## 🚀 Quick Start

### 1️⃣ Install Requirements
```bash
sudo apt update && sudo apt install -y rsync tar gzip cron curl openssh-server
```

### 2️⃣ Create Backup User (vm-source)
```bash
sudo adduser --disabled-password --gecos "Backup User" backupuser
```

### 3️⃣ Generate SSH Keys
```bash
sudo su - backupuser
ssh-keygen -t rsa -b 4096 -f ~/.ssh/backup_key -N ""
ssh-copy-id -i ~/.ssh/backup_key.pub user2@<BACKUP_SERVER_IP>
```

### 4️⃣ Setup Storage (vm-backup)
```bash
mkdir -p ~/received_backups ~/received_csv
chmod 755 ~/received_backups ~/received_csv
```

### 5️⃣ Run First Backup
```bash
~/backup_logs.sh backup
```

## 🛠 Usage Examples
```bash
./backup_logs.sh backup        # Run backup now
./backup_logs.sh add /var/log  # Add new directory
./backup_logs.sh schedule      # Enable automation
./backup_logs.sh restore       # Restore latest backup
```

## 📈 What This System Provides
- Reliable backup pipeline
- Fully automated job scheduling
- Compliance-ready retention system
- Real-time notifications
- Professional logging and reporting

## 🎓 Ideal For
- Homelabs  
- Enterprise log management  
- DevOps automation projects  
- Portfolio building  

## 🤝 Contributing
Issues and pull requests are welcome!

## 📄 License
MIT License – Free to use and modify.

⭐ If this project helped you, give it a star on GitHub!
