property :instance_name, String, name_property: true
property :install_path, String
property :version, String, default: '8.0.36'
property :tarball_base_path, String, default: 'http://archive.apache.org/dist/tomcat/'
property :checksum_base_path, String, default: 'http://archive.apache.org/dist/tomcat/'
property :sha1_base_path, String # this is the legacy name for this attribute
property :exclude_docs, kind_of: [TrueClass, FalseClass], default: true
property :exclude_examples, kind_of: [TrueClass, FalseClass], default: true
property :exclude_manager, kind_of: [TrueClass, FalseClass], default: false
property :exclude_hostmanager, kind_of: [TrueClass, FalseClass], default: false
property :tarball_uri, String
property :tomcat_user, kind_of: String, default: lazy { |r| "tomcat_#{r.instance_name}" }
property :tomcat_group, kind_of: String, default: lazy { |r| "tomcat_#{r.instance_name}" }

action_class do
  # break apart the version string to find the major version
  def major_version
    @major_version ||= new_resource.version.split('.')[0]
  end

  # the install path of this instance of tomcat
  def full_install_path
    if new_resource.install_path
      new_resource.install_path
    else
      @path ||= "/opt/tomcat_#{new_resource.instance_name}_#{new_resource.version.tr('.', '_')}/"
    end
  end

  # build the extraction command based on the passed properties
  def extraction_command
    cmd = "tar -xzf #{Chef::Config['file_cache_path']}/apache-tomcat-#{new_resource.version}.tar.gz -C #{full_install_path} --strip-components=1"
    cmd << " --exclude='*webapps/examples*'" if new_resource.exclude_examples
    cmd << " --exclude='*webapps/ROOT*'" if new_resource.exclude_examples
    cmd << " --exclude='*webapps/docs*'" if new_resource.exclude_docs
    cmd << " --exclude='*webapps/manager*'" if new_resource.exclude_manager
    cmd << " --exclude='*webapps/host-manager*'" if new_resource.exclude_hostmanager
    cmd
  end

  # ensure the version is X.Y.Z format
  def validate_version
    unless new_resource.version =~ /\d+.\d+.\d+/
      Chef::Log.fatal("The version must be in X.Y.Z format. Passed value: #{new_resource.version}")
      raise
    end
  end

  # fetch the md5 checksum from the mirrors
  # we have to do this since the md5 chef expects isn't hosted
  def fetch_checksum
    # preserve the legacy name of sha1_base_path
    new_resource.checksum_base_path = new_resource.sha1_base_path if new_resource.sha1_base_path
    uri = if new_resource.tarball_uri.nil?
            URI.join(new_resource.checksum_base_path, "tomcat-#{major_version}/v#{new_resource.version}/bin/apache-tomcat-#{new_resource.version}.tar.gz.md5")
          else
            URI("#{new_resource.tarball_uri}.md5")
          end
    request = Net::HTTP.new(uri.host, uri.port)
    response = request.get(uri)
    if uri.to_s.start_with?('https')
      request.use_ssl = true
      request.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end

    if response.code != '200'
      Chef::Log.fatal("Fetching the Tomcat tarball checksum at #{uri} resulted in an error #{response.code}")
      raise
    end
    response.body.split(' ')[0]
  rescue => e
    Chef::Log.fatal("Could not fetch the checksum due to an error: #{e}")
    raise
  end

  # validate the mirror checksum against the on disk checksum
  # return true if they match. Append .bad to the cached copy to prevent using it next time
  def validate_checksum(file_to_check)
    desired = fetch_checksum
    actual = Digest::MD5.hexdigest(::File.read(file_to_check))

    if desired == actual
      true
    else
      Chef::Log.fatal("The checksum of the tomcat tarball on disk (#{actual}) does not match the checksum provided from the mirror (#{desired}). Renaming to #{::File.basename(file_to_check)}.bad")
      ::File.rename(file_to_check, "#{file_to_check}.bad")
      raise
    end
  end

  # build the complete tarball URI and handle basepath with/without trailing /
  def tarball_uri
    uri = ''
    if new_resource.tarball_uri.nil?
      uri << new_resource.tarball_base_path
      uri << '/' unless uri[-1] == '/'
      uri << "tomcat-#{major_version}/v#{new_resource.version}/bin/apache-tomcat-#{new_resource.version}.tar.gz"
    else
      uri << new_resource.tarball_uri
    end
    uri
  end
end

action :install do
  validate_version
  # some RHEL systems lack tar in their minimal install
  package 'tar'

  group new_resource.tomcat_group do
    action :create
  end

  user new_resource.tomcat_user do
    gid new_resource.tomcat_group
    shell '/bin/nologin'
    system true
    action :create
  end

  directory 'tomcat install dir' do
    mode '0750'
    path full_install_path
    recursive true
    owner new_resource.tomcat_user
    group new_resource.tomcat_group
  end

  remote_file "apache #{new_resource.version} tarball" do
    source tarball_uri
    path "#{Chef::Config['file_cache_path']}/apache-tomcat-#{new_resource.version}.tar.gz"
    verify { |file| validate_checksum(file) }
  end

  execute 'extract tomcat tarball' do
    command extraction_command
    action :run
    creates ::File.join(full_install_path, 'LICENSE')
  end

  # make sure the instance's user owns the instance install dir
  execute "chown install dir as tomcat_#{new_resource.instance_name}" do
    command "chown -R #{new_resource.tomcat_user}:#{new_resource.tomcat_group} #{full_install_path}"
    action :run
    not_if { Etc.getpwuid(::File.stat("#{full_install_path}/LICENSE").uid).name == new_resource.tomcat_user }
  end

  # create a link that points to the latest version of the instance
  link "/opt/tomcat_#{new_resource.instance_name}" do
    to full_install_path
  end
end
