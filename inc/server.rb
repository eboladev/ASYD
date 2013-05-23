require 'net/ssh'
require 'net/scp'
require 'fileutils'

def srv_init(name, host, password)
  distro,dist_name,dist_ver,pkg_mgr = ""

  Net::SSH.start(host, "root", :password => password) do |ssh|
    ssh.scp.upload!("data/ssh_key.pub", "/tmp/ssh_key.pub")
    ssh.exec "mkdir -p /root/.ssh && touch /root/.ssh/authorized_keys && cat /tmp/ssh_key.pub >> /root/.ssh/authorized_keys && rm /tmp/ssh_key.pub"
    ssh.exec!("cat /etc/issue")  do |channel, stream, data|
      distro << data if stream == :stdout
    end

    distro = distro.split
    dist_name = distro[0]
    dist_ver  = distro[2]

    if dist_name == "Debian" or dist_name == "Ubuntu"
      pkg_mgr = "apt"
    elsif dist_name == "Fedora" or dist_name == "CentOS"
      pkg_mgr = "yum"
    end

  end

  FileUtils.mkdir_p("data/servers/" + name)
  f = File.new("data/servers/"+name+"/srv.info",  "w+")
  f.puts host
  f.puts dist_name
  f.puts dist_ver
  f.puts pkg_mgr
  f.close
end