def srv_init(host, ip, password)
  begin
  servers = SQLite3::Database.new "data/db/servers.db"
  ret = servers.execute("select hostname,ip from servers where hostname=? or ip=?", [host, ip])
  if !ret.empty?
    p ret
    raise DuplicatesFound
  end
  distro,dist_host,dist_ver,arch,pkg_mgr = ""
  o = [('a'..'z'), ('A'..'Z')].map { |i| i.to_a }.flatten
  monit_pw = (0...8).map { o[rand(o.length)] }.join

  Net::SSH.start(ip, "root", :password => password) do |ssh|
    distro = ssh.exec!("cat /etc/issue")
    distro = distro.split
    dist_host = distro[0]

    if dist_host == "Debian" or dist_host == "Ubuntu"
      pkg_mgr = "apt"
      dist_ver  = distro[2]
    elsif dist_host == "Fedora" or dist_host == "CentOS"
      pkg_mgr = "yum"
      dist_ver  = distro[2]
    elsif dist_host == "Arch"
      pkg_mgr = "pacman"
      dist_ver = 0
    else
      exit
    end

    arch = ssh.exec!("uname -m")

    ssh.scp.upload!("data/ssh_key.pub", "/tmp/ssh_key.pub")
    ssh.exec "mkdir -p /root/.ssh && touch /root/.ssh/authorized_keys && cat /tmp/ssh_key.pub >> /root/.ssh/authorized_keys && rm /tmp/ssh_key.pub"

  end

  vars = {}
  vars_srlzd = Marshal.dump(vars)
  servers.execute("INSERT INTO servers (hostname, ip, dist, dist_ver, arch, pkg_mgr, monit_pw, opt_vars) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", [host, ip, dist_host, dist_ver, arch, pkg_mgr, monit_pw, vars_srlzd])
  servers.close

  monitor(host)

  done = host+" successfully added"
  add_notification(2, done, 0)

  rescue SystemExit
    error = 'Unsupported system'
    add_notification(0, error, 0)
    servers.close
  rescue DuplicatesFound
    error = 'Hostname or IP already exists on the system'
    add_notification(0, error, 0)
    servers.close
  end
end

def remove_server(host, revoke)
  if revoke == true
    hostdata = get_host_data(host)
    ip = hostdata[:ip]
    ssh_key = File.open("data/ssh_key.pub", "r").read.strip
    cmd = '/bin/grep -v "'+ssh_key+'" /root/.ssh/authorized_keys > /tmp/auth_keys && mv /tmp/auth_keys /root/.ssh/authorized_keys'
    exec_cmd(ip, cmd)
  end
  servers = SQLite3::Database.new "data/db/servers.db"
  servers.execute("DELETE FROM servers WHERE hostname=?", host)
  servers.close
  groups = get_hostgroup_list
  groups.each do |group|
    del_group_member(group, host)
  end
end

def add_host_var(host, name, value)
  servers = SQLite3::Database.new "data/db/servers.db"
  opt_vars = servers.get_first_row("select opt_vars from servers where hostname=?", host)
  if opt_vars.nil?
    return 4
  else
    if opt_vars[0].nil?
      vars = {}
    else
      vars = Marshal.load(opt_vars[0])
    end
  end
  if vars[name].nil?  # avoid duplicates
    vars[name] = value
  end
  vars_srlzd = Marshal.dump(vars)
  servers.execute("UPDATE servers SET opt_vars=? WHERE hostname=?", [vars_srlzd, host])
  servers.close
end

def del_host_var(host, name)
  servers = SQLite3::Database.new "data/db/servers.db"
  opt_vars = servers.get_first_row("select opt_vars from servers where hostname=?", host)
  if opt_vars.nil?
    return 4
  else
    if opt_vars[0].nil?
      return 4
    else
      vars = Marshal.load(opt_vars[0])
    end
  end
  vars.delete(name)
  vars_srlzd = Marshal.dump(vars)
  servers.execute("UPDATE servers SET opt_vars=? WHERE hostname=?", [vars_srlzd, host])
  servers.close
end
