#!/usr/bin/env bash
# deploy/setup-databases.sh
# ─────────────────────────────────────────────────────────────────────────────
# Installs and configures PostgreSQL 16 + MongoDB 8.0 on a single Ubuntu 24.04
# EC2 instance. Creates all databases, users, schemas, and indexes required by
# the BITE microservices. Optionally seeds test data.
#
# Run as root:  sudo bash setup-databases.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

# ── Header ────────────────────────────────────────────────────────────────────
print_header "BITE — Database Setup Wizard"
printf "  Installs : PostgreSQL 16  +  MongoDB 8.0\n"
printf "  Creates  : users · databases · schema · indexes\n"
printf "  Target   : Ubuntu 24.04 LTS (EC2)\n"
echo
print_warning "Run this on a dedicated DB instance or on the same instance as your services."
print_warning "Databases are NOT started by any other deploy script — this script owns them."

# ═══════════════════════════════════════════════════════════════════════════════
# WIZARD
# ═══════════════════════════════════════════════════════════════════════════════

# ── PostgreSQL ────────────────────────────────────────────────────────────────
print_section "PostgreSQL Configuration"
print_info "Will create database 'inventory' and user 'bite'."
read_var "PostgreSQL 'bite' user password" "" PG_BITE_PASSWORD secret
read_var "Database name" "inventory" PG_DB

# ── MongoDB ───────────────────────────────────────────────────────────────────
print_section "MongoDB Configuration"
print_info "Will create database 'bite_reports', an admin user, and a 'bite' app user."
read_var "MongoDB admin password" "" MONGO_ADMIN_PASSWORD secret
read_var "MongoDB 'bite' user password" "" MONGO_BITE_PASSWORD secret
read_var "Database name" "bite_reports" MONGO_DB

# ── Network ───────────────────────────────────────────────────────────────────
print_section "Network / Remote Access"
print_info "Allow remote connections so services on other EC2s can reach these DBs."
print_info "AWS Security Groups are your primary firewall — restrict by SG, not by IP here."
if confirm "Allow remote connections (bind to 0.0.0.0)?" "y"; then
  BIND_REMOTE="yes"
  read_var "Allowed CIDR in pg_hba.conf" "10.0.0.0/8" ALLOWED_CIDR
else
  BIND_REMOTE="no"
  ALLOWED_CIDR="127.0.0.1/32"
fi

# ── Seed data ─────────────────────────────────────────────────────────────────
print_section "Test Data"
print_info "Seeds PostgreSQL with 5 000 cloud_resource rows."
print_info "Seeds MongoDB with 3 000 cost_reports + 30 monthly_summaries."
if confirm "Seed databases with test data after setup?" "y"; then
  SEED="yes"
else
  SEED="no"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary \
  "PG_DB=${PG_DB}" \
  "PG_BITE_PASSWORD=${PG_BITE_PASSWORD}" \
  "MONGO_DB=${MONGO_DB}" \
  "MONGO_ADMIN_PASSWORD=${MONGO_ADMIN_PASSWORD}" \
  "MONGO_BITE_PASSWORD=${MONGO_BITE_PASSWORD}" \
  "BIND_REMOTE=${BIND_REMOTE}" \
  "ALLOWED_CIDR=${ALLOWED_CIDR}" \
  "SEED_DATA=${SEED}"

confirm "Proceed with installation?" || { echo "Aborted."; exit 0; }

# ═══════════════════════════════════════════════════════════════════════════════
# SYSTEM PREP
# ═══════════════════════════════════════════════════════════════════════════════
print_step "Updating package index"
apt-get update -qq
apt-get install -y curl ca-certificates gnupg lsb-release rsync python3 python3-pip python3-venv --no-install-recommends -qq
print_success "Base packages ready"

# ═══════════════════════════════════════════════════════════════════════════════
# POSTGRESQL 16
# ═══════════════════════════════════════════════════════════════════════════════
print_step "Installing PostgreSQL 16"
apt-get install -y postgresql postgresql-contrib --no-install-recommends -qq
systemctl enable postgresql
systemctl start postgresql
sleep 2
print_success "PostgreSQL $(psql --version | awk '{print $3}') installed and running"

# ── Detect version & paths ────────────────────────────────────────────────────
PG_VER=$(ls /etc/postgresql/ | sort -V | tail -1)
PG_CONF="/etc/postgresql/${PG_VER}/main/postgresql.conf"
PG_HBA="/etc/postgresql/${PG_VER}/main/pg_hba.conf"
print_info "Detected PostgreSQL version: ${PG_VER}"
print_info "Config: ${PG_CONF}"

# ── Network binding ───────────────────────────────────────────────────────────
print_step "Configuring PostgreSQL network access"
if [ "$BIND_REMOTE" = "yes" ]; then
  # Uncomment or set listen_addresses to '*'
  if grep -q "^#listen_addresses" "$PG_CONF"; then
    sed -i "s/^#listen_addresses = 'localhost'/listen_addresses = '*'/" "$PG_CONF"
  else
    sed -i "s/^listen_addresses = .*/listen_addresses = '*'/" "$PG_CONF"
  fi
  print_success "listen_addresses = '*'"

  # Add remote host entry to pg_hba.conf (before existing host lines)
  # Remove any pre-existing bite remote rules to avoid duplicates
  sed -i "/^host.*${PG_DB}.*bite/d" "$PG_HBA"
  printf "host    %-16s bite    %-20s scram-sha-256\n" \
    "${PG_DB}" "${ALLOWED_CIDR}" >> "$PG_HBA"
  print_success "pg_hba.conf: remote access from ${ALLOWED_CIDR} → scram-sha-256"
else
  print_success "Keeping listen_addresses = localhost (local access only)"
fi

# ── Create user, database, schema ─────────────────────────────────────────────
print_step "Creating PostgreSQL role 'bite' and database '${PG_DB}'"
sudo -u postgres psql --no-password -v ON_ERROR_STOP=1 <<SQL
-- Role
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'bite') THEN
    CREATE ROLE bite LOGIN PASSWORD '${PG_BITE_PASSWORD}';
  ELSE
    ALTER ROLE bite WITH PASSWORD '${PG_BITE_PASSWORD}';
  END IF;
END
\$\$;

-- Database
SELECT 'CREATE DATABASE ${PG_DB} OWNER bite'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${PG_DB}') \gexec
SQL
print_success "Role and database created"

print_step "Creating schema in '${PG_DB}'"
sudo -u postgres psql --no-password -d "${PG_DB}" -v ON_ERROR_STOP=1 <<SQL
-- Grant
GRANT ALL PRIVILEGES ON DATABASE ${PG_DB} TO bite;

-- Table (matches inventory-service/models.py)
CREATE TABLE IF NOT EXISTS cloud_resources (
    id            SERIAL PRIMARY KEY,
    company       VARCHAR(100),
    project       VARCHAR(100),
    provider      VARCHAR(50),
    resource_type VARCHAR(100),
    region        VARCHAR(50),
    status        VARCHAR(20),
    cpu_usage     DOUBLE PRECISION  DEFAULT 0.0,
    memory_gb     DOUBLE PRECISION  DEFAULT 0.0,
    monthly_cost  DOUBLE PRECISION  DEFAULT 0.0,
    created_at    TIMESTAMPTZ       DEFAULT NOW()
);

-- Indexes (match seed_postgres.py + SQLAlchemy model index=True)
CREATE INDEX IF NOT EXISTS ix_cloud_resources_id      ON cloud_resources (id);
CREATE INDEX IF NOT EXISTS ix_cloud_resources_company ON cloud_resources (company);
CREATE INDEX IF NOT EXISTS ix_cloud_resources_project ON cloud_resources (project);
CREATE INDEX IF NOT EXISTS idx_company_project        ON cloud_resources (company, project);

-- Transfer ownership so bite user can insert/select
ALTER TABLE cloud_resources OWNER TO bite;
SQL
print_success "Table cloud_resources + 4 indexes created"

# ── Restart & verify ──────────────────────────────────────────────────────────
print_step "Restarting PostgreSQL"
systemctl restart postgresql
sleep 2
if PGPASSWORD="${PG_BITE_PASSWORD}" psql \
    -h 127.0.0.1 -U bite -d "${PG_DB}" -c "SELECT 1" &>/dev/null; then
  print_success "PostgreSQL: bite@127.0.0.1/${PG_DB} connection verified"
else
  print_error "PostgreSQL connection test failed — check: journalctl -u postgresql -n 30"
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# MONGODB 8.0
# ═══════════════════════════════════════════════════════════════════════════════
print_step "Adding MongoDB 8.0 APT repository (Ubuntu Noble)"
curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc \
  | gpg --dearmor -o /usr/share/keyrings/mongodb-server-8.0.gpg
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] \
https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.0 multiverse" \
  > /etc/apt/sources.list.d/mongodb-org-8.0.list
apt-get update -qq
print_success "Repository configured"

print_step "Installing mongodb-org (server + shell + tools)"
apt-get install -y mongodb-org --no-install-recommends -qq
systemctl enable mongod

# ── Start WITHOUT auth for initial user creation ──────────────────────────────
print_step "Starting mongod (pre-auth bootstrap)"
# Ensure auth is OFF for bootstrap — will be enabled after users are created
sed -i '/^security:/,/^[^ ]/{/authorization/d}' /etc/mongod.conf || true
sed -i '/^security:$/d' /etc/mongod.conf             || true
systemctl restart mongod
sleep 3
if ! systemctl is-active --quiet mongod; then
  print_error "mongod failed to start. Check: journalctl -u mongod -n 30"
  exit 1
fi
print_success "mongod started (no-auth mode)"

# ── Create users, collections, indexes in one session ────────────────────────
print_step "Bootstrapping MongoDB users, collections, and indexes"
mongosh --quiet --norc <<MONGOJS
// ── Admin user ───────────────────────────────────────────────────────────────
use admin;
if (db.getUser("admin") === null) {
  db.createUser({
    user: "admin",
    pwd:  "${MONGO_ADMIN_PASSWORD}",
    roles: [
      { role: "userAdminAnyDatabase", db: "admin" },
      { role: "readWriteAnyDatabase", db: "admin" },
      { role: "dbAdminAnyDatabase",   db: "admin" }
    ]
  });
  print("[OK] admin user created");
} else {
  db.updateUser("admin", { pwd: "${MONGO_ADMIN_PASSWORD}" });
  print("[OK] admin password updated");
}

// ── App user ──────────────────────────────────────────────────────────────────
use ${MONGO_DB};
if (db.getUser("bite") === null) {
  db.createUser({
    user: "bite",
    pwd:  "${MONGO_BITE_PASSWORD}",
    roles: [{ role: "readWrite", db: "${MONGO_DB}" }]
  });
  print("[OK] bite user created on ${MONGO_DB}");
} else {
  db.updateUser("bite", { pwd: "${MONGO_BITE_PASSWORD}" });
  print("[OK] bite password updated");
}

// ── Collections (explicit creation before indexing) ───────────────────────────
if (!db.getCollectionNames().includes("cost_reports")) {
  db.createCollection("cost_reports");
  print("[OK] cost_reports collection created");
}
if (!db.getCollectionNames().includes("monthly_summaries")) {
  db.createCollection("monthly_summaries");
  print("[OK] monthly_summaries collection created");
}

// ── Indexes (match seed_mongo.py + report-service query patterns) ─────────────
db.cost_reports.createIndex({ company: -1 },                          { background: true });
db.cost_reports.createIndex({ company: -1, project: -1 },             { background: true });
db.cost_reports.createIndex({ month: -1 },                            { background: true });
db.cost_reports.createIndex({ company: 1, project: 1, month: 1 },     { background: true });
db.monthly_summaries.createIndex({ company: -1, month: -1 },          { background: true });
print("[OK] indexes created on cost_reports + monthly_summaries");
MONGOJS
print_success "Users, collections, and indexes bootstrapped"

# ── Enable auth + configure bindIp ────────────────────────────────────────────
print_step "Enabling MongoDB authentication and configuring bind address"
MONGO_BIND="127.0.0.1"
[ "$BIND_REMOTE" = "yes" ] && MONGO_BIND="0.0.0.0"

# Update net.bindIp
if grep -q "bindIp:" /etc/mongod.conf; then
  sed -i "s/bindIp: .*/bindIp: ${MONGO_BIND}/" /etc/mongod.conf
else
  sed -i "/^net:/a\  bindIp: ${MONGO_BIND}" /etc/mongod.conf
fi

# Append security block (we removed any old one above)
cat >> /etc/mongod.conf <<MONGOCFG

security:
  authorization: enabled
MONGOCFG
print_success "mongod.conf: bindIp=${MONGO_BIND}, authorization=enabled"

# ── Restart & verify ──────────────────────────────────────────────────────────
print_step "Restarting mongod with auth enabled"
systemctl restart mongod
sleep 3
if ! systemctl is-active --quiet mongod; then
  print_error "mongod failed after enabling auth. Check: journalctl -u mongod -n 30"
  exit 1
fi
# Verify bite user can connect and see its db
if mongosh "mongodb://bite:${MONGO_BITE_PASSWORD}@127.0.0.1:27017/${MONGO_DB}?authSource=${MONGO_DB}" \
    --quiet --norc --eval "db.runCommand({ping:1}).ok === 1" | grep -q "true"; then
  print_success "MongoDB: bite@127.0.0.1/${MONGO_DB} connection verified"
else
  print_error "MongoDB bite user connection test failed."
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# OPTIONAL SEED
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$SEED" = "yes" ]; then
  # ── PostgreSQL seed ──────────────────────────────────────────────────────────
  print_step "Seeding PostgreSQL — inserting 5 000 cloud_resource rows"
  PGPASSWORD="${PG_BITE_PASSWORD}" psql \
    -h 127.0.0.1 -U bite -d "${PG_DB}" -v ON_ERROR_STOP=1 -q <<'PGSEED'
INSERT INTO cloud_resources
  (company, project, provider, resource_type, region, status, cpu_usage, memory_gb, monthly_cost)
SELECT
  (ARRAY['Bancolombia','EPM','Grupo Exito','Avianca','Postobón'])[1 + floor(random()*5)::int],
  (ARRAY['DataLake','CRM','ERP','Analytics','WebApp'])[1 + floor(random()*5)::int],
  (ARRAY['AWS','GCP','Azure'])[1 + floor(random()*3)::int],
  (ARRAY['EC2','RDS','S3','Lambda','BigQuery','GKE','AzureVM'])[1 + floor(random()*7)::int],
  (ARRAY['us-east-1','us-west-2','eu-west-1','sa-east-1'])[1 + floor(random()*4)::int],
  (ARRAY['running','stopped','idle'])[1 + floor(random()*3)::int],
  round((random()*100)::numeric, 2),
  round((0.5 + random()*63.5)::numeric, 2),
  round((5 + random()*495)::numeric, 2)
FROM generate_series(1, 5000);
PGSEED
  print_success "PostgreSQL: 5 000 rows inserted into cloud_resources"

  # ── MongoDB seed ─────────────────────────────────────────────────────────────
  print_step "Seeding MongoDB — 3 000 cost_reports + 30 monthly_summaries"
  mongosh "mongodb://bite:${MONGO_BITE_PASSWORD}@127.0.0.1:27017/${MONGO_DB}?authSource=${MONGO_DB}" \
    --quiet --norc <<'MONGOSEED'
const companies = ["Bancolombia","EPM","Grupo Exito","Avianca","Postobón"];
const projects  = ["DataLake","CRM","ERP","Analytics","WebApp"];
const months    = ["2024-10","2024-11","2024-12","2025-01","2025-02","2025-03"];
const pick      = arr => arr[Math.floor(Math.random() * arr.length)];
const rand      = (lo, hi) => Math.round((lo + Math.random()*(hi-lo)) * 100) / 100;

// cost_reports
const reports = [];
for (let i = 0; i < 3000; i++) {
  const total = rand(500, 50000);
  const waste = Math.round(total * (0.1 + Math.random()*0.4) * 100) / 100;
  reports.push({
    company:            pick(companies),
    project:            pick(projects),
    month:              pick(months),
    total_cost:         total,
    waste_cost:         waste,
    currency:           "USD",
    resources_analyzed: Math.floor(10 + Math.random()*490),
    created_at:         new Date()
  });
}
db.cost_reports.insertMany(reports);
print("[OK] 3 000 cost_reports inserted");

// monthly_summaries
const summaries = [];
for (const company of companies) {
  for (const month of months) {
    summaries.push({
      company,
      month,
      total_cost:  rand(10000, 200000),
      total_waste: rand(1000,  50000),
      top_project: pick(projects)
    });
  }
}
db.monthly_summaries.insertMany(summaries);
print("[OK] 30 monthly_summaries inserted");
MONGOSEED
  print_success "MongoDB: 3 000 cost_reports + 30 monthly_summaries inserted"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# DETECT PRIVATE IP
# ═══════════════════════════════════════════════════════════════════════════════
print_step "Detecting instance private IP"
PRIVATE_IP=""
# Try EC2 IMDSv2 first
TOKEN=$(curl -sf --connect-timeout 2 \
  -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null) || true
if [ -n "${TOKEN:-}" ]; then
  PRIVATE_IP=$(curl -sf --connect-timeout 2 \
    -H "X-aws-ec2-metadata-token: $TOKEN" \
    "http://169.254.169.254/latest/meta-data/local-ipv4" 2>/dev/null) || true
fi
# Fallback to hostname
[ -z "${PRIVATE_IP:-}" ] && PRIVATE_IP=$(hostname -I | awk '{print $1}')
print_success "Private IP: ${PRIVATE_IP}"

# ═══════════════════════════════════════════════════════════════════════════════
# SAVE CREDENTIALS
# ═══════════════════════════════════════════════════════════════════════════════
print_step "Saving connection strings to /opt/bite/db-credentials.env"
mkdir -p /opt/bite
{
  printf '# BITE Database Credentials — generated %s\n' "$(date -u '+%Y-%m-%d %H:%M UTC')"
  printf '# Mode 600 — do not commit this file.\n\n'
  printf '# PostgreSQL (inventory-service)\n'
  printf 'DATABASE_URL=postgresql://bite:%s@%s:5432/%s\n' \
    "$PG_BITE_PASSWORD" "$PRIVATE_IP" "$PG_DB"
  printf '\n'
  printf '# MongoDB (report-service)\n'
  printf 'MONGO_URL=mongodb://bite:%s@%s:27017/%s?authSource=%s\n' \
    "$MONGO_BITE_PASSWORD" "$PRIVATE_IP" "$MONGO_DB" "$MONGO_DB"
  printf '\n'
  printf '# MongoDB admin (maintenance only)\n'
  printf 'MONGO_ADMIN_URL=mongodb://admin:%s@%s:27017/?authSource=admin\n' \
    "$MONGO_ADMIN_PASSWORD" "$PRIVATE_IP"
} > /opt/bite/db-credentials.env
chmod 600 /opt/bite/db-credentials.env
print_success "Credentials saved (mode 600)"

# ═══════════════════════════════════════════════════════════════════════════════
# FINAL OUTPUT
# ═══════════════════════════════════════════════════════════════════════════════
PG_URL="postgresql://bite:${PG_BITE_PASSWORD}@${PRIVATE_IP}:5432/${PG_DB}"
MONGO_URL="mongodb://bite:${MONGO_BITE_PASSWORD}@${PRIVATE_IP}:27017/${MONGO_DB}?authSource=${MONGO_DB}"

echo
printf "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "  ${GREEN}${BOLD}✓ Database setup complete!${NC}\n"
printf "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n\n"

printf "  ${BOLD}Service status:${NC}\n"
systemctl is-active --quiet postgresql && \
  printf "  ${GREEN}●${NC} postgresql    running  (port 5432)\n" || \
  printf "  ${RED}○${NC} postgresql    STOPPED\n"
systemctl is-active --quiet mongod && \
  printf "  ${GREEN}●${NC} mongod         running  (port 27017)\n" || \
  printf "  ${RED}○${NC} mongod         STOPPED\n"

echo
printf "  ${BOLD}Connection strings (copy into service .env files):${NC}\n\n"
printf "  ${CYAN}# inventory-service${NC}\n"
printf "  DATABASE_URL=%s\n\n" "$PG_URL"
printf "  ${CYAN}# report-service${NC}\n"
printf "  MONGO_URL=%s\n\n" "$MONGO_URL"

printf "  ${BOLD}Saved to:${NC} /opt/bite/db-credentials.env  (mode 600)\n"
echo
printf "  ${BOLD}Quick health checks:${NC}\n"
printf "  ${CYAN}PGPASSWORD='%s' psql -h %s -U bite -d %s -c '\\dt'${NC}\n" \
  "$PG_BITE_PASSWORD" "$PRIVATE_IP" "$PG_DB"
printf "  ${CYAN}mongosh '%s' --eval 'db.cost_reports.countDocuments()'${NC}\n" \
  "$MONGO_URL"
echo
printf "  ${BOLD}Next steps:${NC}\n"
printf "   1. Open EC2 Security Group inbound rules:\n"
printf "        port 5432  (PostgreSQL) ← from inventory-service SG\n"
printf "        port 27017 (MongoDB)    ← from report-service SG\n"
printf "   2. Deploy services — use the connection strings above:\n"
printf "        sudo bash deploy-inventory-service.sh\n"
printf "        sudo bash deploy-report-service.sh\n"
printf "   3. Pass DATABASE_URL / MONGO_URL to the api-gateway instance:\n"
printf "        the gateway reads INVENTORY_URL and REPORT_URL (service URLs,\n"
printf "        not DB URLs) — update its .env with the service private IPs.\n"
echo
