class TeamboxData < ActiveRecord::Base
  belongs_to :user
  concerned_with :serialization, :attributes, :teambox, :basecamp
  
  attr_accessible :project_ids, :type_name, :import_data, :user_map, :target_organization, :service
  
  before_validation_on_create :set_service
  before_create :check_state
  before_update :check_state
  
  has_attached_file :processed_data,
    :url  => "/exports/:id/:basename.:extension",
    :path => Teambox.config.amazon_s3 ?
      "exports/:id/:filename" :
      ":rails_root/exports/:id/:filename"
  
  validate :check_map
  
  def check_map
    @errors.add "service", "Unknown service #{service}" if !['teambox', 'basecamp'].include?(service)
    if type_name == :import and status_name == :mapping
      # user needs to be an admin of the target organization
      if !user.admin_organizations.map(&:permalink).include?(target_organization)
        return @errors.add("target_organization", "Should be an admin")
      end
      
      # All users need to be known to the owner
      users = user.organizations.map{|o| o.users + o.users_in_projects }.flatten.compact.map(&:login)
      
      user_map.each do |login,dest_login|
        if !users.include?(dest_login)
          @errors.add "user_map_#{login}", "#{dest_login} Not known to user #{users.inspect} [#{user_map.inspect}]"
        end
      end
    end
  end
  
  def set_service
    self.service ||= 'teambox'
  end
  
  def store_import_data
    begin
      # store the import in a temporary file, since we don't need it for long
      bytes = @import_data.read
      self.processed_data_file_name = "#{user.name}-import.json"
      File.open("/tmp/#{processed_data_file_name}", 'w') do |f|
        f.write bytes
      end
      self.status_name = :mapping
    rescue Exception => e
      @process_error = e.to_s
      self.processed_data_file_name = nil
      self.status_name = :uploading
    end
  end
  
  def need_data?
    if type_name == :import
      status < IMPORT_STATUSES[:pre_processing]
    else
      status < EXPORT_STATUSES[:pre_processing]
    end
  end
  
  def check_state
    @check_state = true
    if type_name == :import
      case status_name
      when :uploading
        if self.processed_data_file_name and File.exists?("/tmp/#{processed_data_file_name}")
          self.status_name = :mapping
        elsif @import_data
          store_import_data
        else
          self.processed_data_file_name = nil
        end
      when :mapping
        self.status_name = :processing
        if Teambox.config.delay_data_processing
          self.status_name = :pre_processing
          send_later(:do_import)
        else
          self.status_name = :processing
          do_import
        end
      end
    else
      case status_name
      when :selecting
        if Teambox.config.delay_data_processing
          self.status_name = :pre_processing
          send_later(:do_export)
        else
          self.status_name = :processing
          do_export
        end
      end
    end
  end
  
  def do_import
    self.processed_at = Time.now
    do_deliver = ActionMailer::Base.perform_deliveries
    next_status = :imported
    
    begin
      org_map = {}
      organizations.each do |org|
        org_map[org['permalink']] = target_organization
      end
      
      ActionMailer::Base.perform_deliveries = false
      if service == 'basecamp'
        unserialize_basecamp({'User' => user_map, 'Organization' => org_map})
      else
        unserialize({'User' => user_map, 'Organization' => org_map})
      end
    rescue Exception => e
      # Something went wrong?!
      self.processed_at = nil
      next_status = :processing
      if new_record? or @check_state
        destroy
        return
      end
    end
    
    self.status_name = next_status
    ActionMailer::Base.perform_deliveries = do_deliver
    FileUtils.rm("/tmp/#{processed_data_file_name}")
    self.processed_data_file_name = nil
    save unless new_record? or @check_state
  end
  
  def do_export
    self.processed_at = Time.now
    @data = serialize(organizations_to_export, projects, users_to_export)
    upload = ActionController::UploadedStringIO.new
    upload.write(@data.to_json)
    upload.seek(0)
    upload.original_path = "#{user.login}-export.json"
    self.processed_data = upload
    self.status_name = :exported
    save unless new_record? or @check_state
  end
  
  def exported?
    type_name == :import && status > EXPORT_STATUSES[:processing]
  end
  
  def imported?
    type_name == :import && status > IMPORT_STATUSES[:processing]
  end
  
  def processing?
    type_name == :import ? [IMPORT_STATUSES[:pre_processing], IMPORT_STATUSES[:processing]].include?(status) :
                           [EXPORT_STATUSES[:pre_processing], EXPORT_STATUSES[:processing]].include?(status)
  end
  
  def project_ids=(value)
    write_attribute :project_ids, Array(value).map(&:to_i).compact
  end
  
  def projects
    Project.find(:all, :conditions => {:id => project_ids})
  end
  
  def organizations_to_export
    Organization.find(:all, :conditions => {:projects => {:id => project_ids}}, :joins => [:projects])
  end
  
  def users_to_export
    organizations_to_export.map{|o| o.users + o.users_in_projects }.flatten.compact
  end
end