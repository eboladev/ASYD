module Monitoring

  TTL = 15 #store/refresh the status for 15 seconds

  class Notification
    include DataMapper::Resource

    def self.default_repository_name #here we use the monitoring_db for the Monitoring::Notification objects
     :monitoring_db
    end

    property :id, Serial
    property :type, Enum[ :error, :info, :success ], :lazy => false
    property :acknowledge, Boolean, :default => false
    property :host_hostname, String
    property :service, String
    property :message, Text, :lazy => false
    property :sticky, Boolean, :default => true #keep for compatibility
    property :dismiss, Boolean, :default => false, :lazy => false
    property :created_at, DateTime
    property :updated_at, DateTime
    property :inclass, Discriminator
  end

  module Host
    include Misc

    def monitor
      begin
        ret = Deploy.launch(self, "monit", nil)
        if ret != 1
          raise ExecutionError, ret[1]
        end
        self.monitored = true
        self.save
      rescue ExecutionError => e
        NOTEX.synchronize do
          msg = "Unable to monitor host "+self.hostname+": "+e.message
          ::Notification.create(:type => :error, :sticky => true, :message => msg)
        end
      end
    end

    def monitor_service(service)
      begin
        unless File.exists?("data/monitors/"+service)
          raise
        end
        parsed_cfg = Deploy.parse_config(self, "data/monitors/"+service)
        if self.user != "root"
          upload_file(parsed_cfg.path, "/tmp/"+service)
          exec_cmd("sudo mv /tmp/"+service+" /etc/monit/conf.d/"+service)
          exec_cmd("sudo chown root:root /etc/monit/conf.d/"+service)
          exec_cmd("sudo /usr/bin/monit -c /etc/monit/monitrc reload")
        else
          upload_file(parsed_cfg.path, "/etc/monit/conf.d/"+service)
          exec_cmd("/usr/bin/monit -c /etc/monit/monitrc reload")
        end
        parsed_cfg.unlink
      rescue
        NOTEX.synchronize do
          msg = "Monitor file not found for service "+service
          ::Notification.create(:type => :error, :sticky => true, :message => msg)
        end
      end
    end

    def get_status
      short = true
      stat = Status.new(self, short)
      status = 1
      if stat.system_status.nil? || stat.system_status == 'down'
        status = 3
      else
        if stat.system_status != 'ok'
          status = 2
        end
        stat.services.each do |service|
          if service[1] != 'ok'
            status = 2
          end
        end unless stat.services.nil?
      end
      MOTEX.synchronize do
        hoststatus = HostStatus.first(:host_hostname => self.hostname)
        if hoststatus.nil?
          hoststatus = HostStatus.create(:host_hostname => self.hostname, :status => status)
        else
          hoststatus.update(:status => status)
        end
      end
      return status
    end

    def get_full_status
      short = false
      stat = Status.new(self, short)
      return stat
    end

    # @param refresh [Boolean] refresh the status?
    # Status codes:
    # 4 == not monitored
    # 3 == host down
    # 2 == problem
    # 1 == all ok
    def is_ok?
      if self.monitored == false
        return 4
      else
        hoststatus = nil
        MOTEX.synchronize do
          hoststatus = HostStatus.first(:host_hostname => self.hostname)
        end
        if hoststatus.nil?
          return self.get_status
        else
          return hoststatus.status
        end
      end
    end
  end

  module Hostgroup
    def members_status
      stat = {}
      stat[:total] = self.hosts.count
      stat[:failed] = 0
      stat[:sane] = 0
      if stat[:total] == 0
        return stat
      else
        self.hosts.each do |host|
          ret = host.is_ok?
          if ret != 1
            stat[:failed] = stat[:failed] + 1
          end
        end
        stat[:sane] = stat[:total] - stat[:failed]
        return stat
      end
    end
  end

  def self.background
    while true
      max_forks = 15 #we hard limit the max checks to 15 at a time
      forks = [] #and initialize an empty array
      hosts = ::Host.all
      hosts.each do |host|
        if forks.count >= max_forks #if we reached the max forks
          id = Process.wait #then we wait for some child to finish
          forks.delete(id) #and we remove it from the forks array
        end
        frk = Spork.spork do #so we can continue executing a new fork
          if host.monitored #do things
            stat = host.get_status
            if stat == 3 #the host is down
              MNOTEX.synchronize do
                last = Monitoring::Notification.last(:host_hostname => host.hostname)
                if last.nil? #no previous notification
                  error = "Unable to get monitoring status for host "+host.hostname
                  Monitoring::Notification.create(:type => :error, :message => error, :host_hostname => host.hostname, :service => "system")
                else
                  if last.acknowledge == false && last.dismiss == true #the last notification was already dismissed and is not acknowledged
                    error = "Unable to get monitoring status for host "+host.hostname
                    Monitoring::Notification.create(:type => :error, :message => error, :host_hostname => host.hostname, :service => "system")
                  end
                end
              end
            else #the host recovered?
              MNOTEX.synchronize do
                last = Monitoring::Notification.last(:host_hostname => host.hostname)
                if !last.nil?
                  last.update(:acknowledge => false, :dismiss => true)
                end
              end
            end
          end
        end
        forks << frk #and store the fork id on the forks array
      end
      Process.waitall
      sleep TTL
    end
  end
end
