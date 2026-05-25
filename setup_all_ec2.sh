#!/bin/bash

KEY="~/.ssh/labsuser.pem"
SSH_OPTS="-o StrictHostKeyChecking=no -i $KEY"

GW_IP=""
INV_IP=""
REPORT_IP=""
NOTIF_IP=""
POSTGRES_IP=""
MONGO_IP=""

INSTANCES=("$GW_IP" "$INV_IP" "$REPORT_IP" "$NOTIF_IP" "$POSTGRES_IP" "$MONGO_IP")
NAMES=("ec2-gateway" "ec2-inventory" "ec2-report" "ec2-notification" "ec2-postgres" "ec2-mongo")

install_docker() {
    local ip=$1
    local name=$2
    echo "[$name] Instalando Docker en $ip..."
    ssh $SSH_OPTS ec2-user@$ip << 'ENDSSH'
sudo yum update -y
sudo yum install -y git docker
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -aG docker ec2-user
ENDSSH
    if [ $? -eq 0 ]; then
        echo "[$name] Docker instalado correctamente"
    else
        echo "[$name] ERROR al instalar Docker"
    fi
}

for i in "${!INSTANCES[@]}"; do
    install_docker "${INSTANCES[$i]}" "${NAMES[$i]}" &
done

wait
echo "Instalacion completada en todas las instancias"
