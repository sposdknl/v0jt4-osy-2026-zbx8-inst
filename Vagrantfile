Vagrant.configure("2") do |config|
  config.vm.box = "bento/debian-13"
  config.vm.hostname = "zbx8-dabaca4444"

  config.vm.network "forwarded_port", guest: 80, host: 8080, host_ip: "127.0.0.1", id: "http"
  config.vm.network "forwarded_port", guest: 22, host: 2222, host_ip: "127.0.0.1", id: "ssh", auto_correct: true

  config.vm.provider "virtualbox" do |vb|
    vb.name   = "kozakv-zabbix"
    vb.cpus   = 2
    vb.memory = 2048
  end

  config.vm.provision "shell",
    name: "install-zabbix",
    path: "scripts/install-zabbix.sh",
    env: {
      "ZBX_SERVER_NAME"    => "kozakv | Zabbix 8.0 LTS",
      "ZBX_DB_PASSWORD"    => ENV["ZBX_DB_PASSWORD"].to_s,
      "ZBX_ADMIN_PASSWORD" => ENV["ZBX_ADMIN_PASSWORD"].to_s,
      "ZBX_TIMEZONE"       => "Europe/Prague"
    }

  config.vm.provision "shell",
    name: "import-host",
    path: "scripts/import-host.sh",
    args: ["/vagrant/Zabbix/export"],
    env: { "ZBX_ADMIN_PASSWORD" => ENV["ZBX_ADMIN_PASSWORD"].to_s },
    run: "never"
end
