class ApiV1::APIController < ApplicationController
  skip_before_filter :load_organization
  skip_before_filter :rss_token, :recent_projects, :touch_user, :verify_authenticity_token

  API_LIMIT = 50
  API_NONNUMERIC = /[^0-9]+/

  protected
  
  rescue_from CanCan::AccessDenied do |exception|
    api_status(:unauthorized)
  end
  
  def load_project
    project_id ||= params[:project_id]
    
    if project_id
      @current_project = if project_id.match(API_NONNUMERIC)
        Project.find_by_permalink(project_id)
      else
        Project.find_by_id(project_id)
      end
      api_status(:not_found) unless @current_project
    end
  end
  
  def load_organization
    if params[:organization_id]
      @organization = if params[:organization_id].match(API_NONNUMERIC)
        current_user.organizations.find_by_permalink(params[:organization_id])
      else
        current_user.organizations.find_by_id(params[:organization_id])
      end
    end
    api_status(:not_found) if params[:organization_id] and @organization.nil?
  end
  
  def belongs_to_project?
    if @current_project
      unless Person.exists?(:project_id => @current_project.id, :user_id => current_user.id)
        api_error t('common.not_allowed'), :unauthorized
      end
    end
  end
  
  def check_permissions
    unless @current_project.editable?(current_user)
      api_error "You don't have permission to edit/update/delete within \"#{@current_project}\" project", :unauthorized
    end
  end
  
  def load_task_list
    if @current_project && params[:task_list_id]
      @task_list = @current_project.task_lists.find(params[:task_list_id])
    end
  end
  
  def load_page
    @page = @current_project.pages.find params[:page_id]
    api_status(:not_found) unless @page
  end

  # Common api helpers
  
  def api_respond(object, options={})
    respond_to do |f|
      f.json { render :json => api_wrap(object, options).to_json }
      f.js   { render :json => api_wrap(object, options).to_json, :callback => params[:callback] }
    end
  end
  
  def api_status(status)
    respond_to do |f|
      f.json { head status }
      f.js   { render :json => {:status => status}.to_json, :status => status, :callback => params[:callback] }
    end
  end
  
  def api_wrap(object, options={})
    objects = if object.is_a? Enumerable
      object.map{|o| o.to_api_hash(options) }
    else
      object.to_api_hash(options)
    end
    
    if options[:references]
      { :references => Array(object).map{ |obj|  
          options[:references].map{|ref| obj.send(ref)}
        }.flatten.compact.uniq.map{|o| o.to_api_hash(options.merge(:emit_type => true))},
        :objects => objects }
    else
      objects
    end
  end
  
  def api_error(message, status)
    error = {'message' => message}
    respond_to do |f|
      f.json { render :as_json => error.to_xml(:root => 'error'), :status => status }
      f.js { render :json => error.to_xml(:root => 'error'), :status => status, :callback => params[:callback] }
    end
  end
  
  def handle_api_error(object,options={})
    error_list = object.nil? ? [] : object.errors
    respond_to do |f|
      f.json { render :as_json => error_list.to_xml, :status => options.delete(:status) || :unprocessable_entity }
      f.js   { render :json => error_list.to_xml, :status => options.delete(:status) || :unprocessable_entity, :callback => params[:callback] }
    end
  end
  
  def handle_api_success(object,options={})
    respond_to do |f|
      if options.delete(:is_new) || false
        f.json { render :json => api_wrap(object, options).to_json, :status => options.delete(:status) || :created }
        f.js   { render :json => api_wrap(object, options).to_json, :status => options.delete(:status) || :created }
      else
        f.json { head(options.delete(:status) || :ok) }
        f.js   { render :json => {:status => options.delete(:status) || :ok}.to_json, :callback => params[:callback] }
      end
    end
  end
  
  def api_truth(value)
    ['true', '1'].include?(value) ? true : false
  end
  
  def api_limit
    if params[:count]
      [params[:count].to_i, API_LIMIT].min
    else
      API_LIMIT
    end
  end
  
  def api_range
    since_id = params[:since_id]
    max_id = params[:max_id]
    
    if since_id and max_id
      ['id > ? AND id < ?', since_id, max_id]
    elsif since_id
      ['id > ?', since_id]
    elsif max_id
      ['id < ?', max_id]
    else
      []
    end
  end
  
  def set_client
    request.format = :json unless request.format == :js
  end
  
end