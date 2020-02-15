class Timesheet
  extend ActiveModel::Naming
  include ActiveModel::Conversion
  attr_accessor :date_from, :date_to, :projects, :activities, :users, :groups, :trackers,
    :allowed_projects, :period, :period_type

  # Time entries on the Timesheet in the form of:
  #   project.name => {:logs => [time entries], :users => [users shown in logs] }
  #   project.name => {:logs => [time entries], :users => [users shown in logs] }
  # project.name could be the parent project name also
  attr_accessor :time_entries

  # Array of TimeEntry ids to fetch
  attr_accessor :potential_time_entry_ids
  attr_accessor :spent_on

  # Sort time entries by this field
  attr_accessor :sort
  ValidSortOptions = {
    :project => 'Project',
    :user => 'User',
    :issue => 'Issue',
    :group => 'Group',
    :tracker => 'Tracker',
    :date => 'Date'
  }

  ValidPeriodType = {
    :free_period => 0,
    :default => 1
  }

  def initialize(options = { })
    self.projects = [ ]
    self.time_entries = options[:time_entries] || { }
    self.potential_time_entry_ids = options[:potential_time_entry_ids] || [ ]
    self.allowed_projects = options[:allowed_projects] || [ ]
    self.groups = [ ]
    self.trackers = [ ]

    unless options[:activities].nil?
      self.activities = options[:activities].collect do |activity_id|
        # Include project-overridden activities
        activity = TimeEntryActivity.find(activity_id)
        project_activities = TimeEntryActivity.where(['parent_id IN (?)', activity.id]) if activity.parent_id.nil?
        project_activities ||= []

        [activity.id.to_i] + project_activities.collect(&:id)
      end.flatten.uniq.compact
    else
      self.activities =  TimeEntryActivity.all.collect { |a| a.id.to_i }
    end

    unless options[:users].nil?
      self.users = options[:users].collect { |u| u.to_i }
    else
      self.users = Timesheet.viewable_users.collect {|user| user.id.to_i }
    end
    
    if User.current.allowed_to?(:see_all_project_timesheets, nil, :global => true)
      unless options[:groups].nil?
        self.groups= options[:groups].collect { |g| g.to_i }
        groups = Group.where(:id => self.groups)
        # This new flag (off by default) clear users list before applying group filter
        # so the group filter does not depend on the user filter
        if Setting.plugin_redmine_timesheet_plugin['group_override']
          self.users = []
        end
        groups.each do |group|
          self.users += group.user_ids
        end
        self.users.uniq!
      else
        self.groups= Group.all
      end
    end

    unless options[:trackers].nil?
      self.trackers = options[:trackers].collect do |tracker_id|
        tracker = Tracker.find(tracker_id)
        tracker.id if tracker
      end.flatten.uniq.compact
    end

    if !options[:sort].nil? && options[:sort].respond_to?(:to_sym) && ValidSortOptions.keys.include?(options[:sort].to_sym)
      self.sort = options[:sort].to_sym
    else
      self.sort = :project
    end

    self.date_from = options[:date_from] || Date.today.to_s
    self.date_to = options[:date_to] || Date.today.to_s
    self.spent_on=options[:spent_on]

    if options[:period_type] && ValidPeriodType.values.include?(options[:period_type].to_i)
      self.period_type = options[:period_type].to_i
    else
      self.period_type = ValidPeriodType[:free_period]
    end
    self.period = options[:period] || nil
  end

  # Gets all the time_entries for all the projects
  def fetch_time_entries
    self.time_entries = { }
    case self.sort
    when :project
      fetch_time_entries_by_project
    when :user
      fetch_time_entries_by_user
    when :issue
      fetch_time_entries_by_issue
    when :group
      fetch_time_entries_by_group
    when :tracker
      fetch_time_entries_by_tracker
    when :date
      fetch_time_entries_by_date
    else
      fetch_time_entries_by_project
    end
  end

  def period=(period)
    return if self.period_type == Timesheet::ValidPeriodType[:free_period]
    # Stolen from the TimelogController
    case period.to_s
    when 'today'
      self.date_from = self.date_to = Date.today
    when 'yesterday'
      self.date_from = self.date_to = Date.today - 1
    when 'current_week' # Mon -> Sun
      self.date_from = Date.today - (Date.today.cwday - 1)%7
      self.date_to = self.date_from + 6
    when 'last_week'
      self.date_from = Date.today - 7 - (Date.today.cwday - 1)%7
      self.date_to = self.date_from + 6
    when '7_days'
      self.date_from = Date.today - 7
      self.date_to = Date.today
    when 'current_month'
      self.date_from = Date.civil(Date.today.year, Date.today.month, 1)
      self.date_to = (self.date_from >> 1) - 1
    when 'last_month'
      self.date_from = Date.civil(Date.today.year, Date.today.month, 1) << 1
      self.date_to = (self.date_from >> 1) - 1
    when '30_days'
      self.date_from = Date.today - 30
      self.date_to = Date.today
    when 'current_year'
      self.date_from = Date.civil(Date.today.year, 1, 1)
      self.date_to = Date.civil(Date.today.year, 12, 31)
    when 'all'
      self.date_from = self.date_to = nil
    end
    self
  end

  def to_param
    {
      :projects => projects.collect(&:id),
      :date_from => date_from,
      :date_to => date_to,
      :activities => activities,
      :users => users,
      :sort => sort
    }
  end

  def to_csv
    out = "";
    FCSV.generate(out, :encoding => 'utf-8', :force_quotes => true) do |csv|
      csv << csv_header

      # Write the CSV based on the group/sort
      case sort
      when :user, :project
        time_entries.sort.each do |entryname, entry|
          entry[:logs].each do |e|
            csv << time_entry_to_csv(e)
          end
        end
      when :issue
        time_entries.sort.each do |project, entries|
          entries[:issues].sort {|a,b| a[0].id <=> b[0].id}.each do |issue, time_entries|
            time_entries.each do |e|
              csv << time_entry_to_csv(e)
            end
          end
        end
      end
    end
    out
  end

  def self.viewable_users
    if Setting.plugin_redmine_timesheet_plugin.present? && Setting.plugin_redmine_timesheet_plugin['user_status'] == 'all'
      if User.current.allowed_to?(:see_all_project_timesheets, nil, :global => true)
        user_scope = User.all
      else
        user_scope = [User.current]
      end
    else
      if User.current.allowed_to?(:see_all_project_timesheets, nil, :global => true)
        user_scope = User.active
      else
        user_scope = [User.current]
      end
    end

    user_scope.select {|user|
      user.allowed_to?(:log_time, nil, :global => true)
    }
  end

  protected

  def csv_header
    csv_data = [
      '#',
      l(:label_date),
      l(:label_member),
      l(:label_tracker),
      l(:label_activity),
      l(:label_project),
      l(:label_version),
      l(:label_issue),
      "#{l(:label_issue)} #{l(:field_subject)}",
      l(:field_comments),
      l(:field_hours)
    ]
    Redmine::Hook.call_hook(:plugin_timesheet_model_timesheet_csv_header, { :timesheet => self, :csv_data => csv_data})
    return csv_data
  end

  def time_entry_to_csv(time_entry)
    csv_data = [
      time_entry.id,
      time_entry.spent_on,
      time_entry.user.name,
      time_entry.issue && time_entry.issue.tracker.name,
      time_entry.activity.name,
      time_entry.project,
      (time_entry.issue.fixed_version if time_entry.issue),
      ("#{time_entry.issue.tracker.name} ##{time_entry.issue.id}" if time_entry.issue),
      (time_entry.issue.subject if time_entry.issue),
      time_entry.comments,
      time_entry.hours
    ]
    Redmine::Hook.call_hook(:plugin_timesheet_model_timesheet_time_entry_to_csv, { :timesheet => self, :time_entry => time_entry, :csv_data => csv_data})
    return csv_data
  end

  # Array of users to find
  # String of extra conditions to add onto the query (AND)
  def conditions(users, trackers, extra_conditions=nil)
    condition_str = []
    condition_params = []
    if self.potential_time_entry_ids.empty?
      if self.date_from.present?
        condition_str << "spent_on >= ?"
        condition_params << self.date_from
      end
      
      if self.date_to.present?
        condition_str << "spent_on <= ?"
        condition_params << self.date_to
      end
      if self.projects.present?
        condition_str << "#{TimeEntry.table_name}.project_id IN (?)"
        condition_params << self.projects
      end
      if self.activities.present?
        condition_str << "activity_id IN (?)"
        condition_params << self.activities      
      end
    else
      condition_str << "#{TimeEntry.table_name}.id IN (?)"
      condition_params << self.potential_time_entry_ids
    end
    if users.present?
      condition_str << "user_id IN (?)"
      condition_params << users      
    end

    if trackers.present?
      condition_str << "tracker_id IN (?)"
      condition_params << trackers      
    end     

    if extra_conditions
      condition_str << extra_conditions
    end

    conditions = [condition_str.join(' AND ')].concat condition_params
    Redmine::Hook.call_hook(:plugin_timesheet_model_timesheet_conditions, { :timesheet => self, :conditions => conditions})
    return conditions
  end

  def includes
    includes = [:activity, :user, :project, {:issue => [:tracker, :assigned_to, :priority]}]
    Redmine::Hook.call_hook(:plugin_timesheet_model_timesheet_includes, { :timesheet => self, :includes => includes})
    return includes
  end

  private


  def time_entries_for_all_users(project)
    return project.time_entries.eager_load(self.includes).
      where(self.conditions(self.users, self.trackers)).
      order('spent_on ASC')
  end

  def time_entries_for_all_users_in_group(group)
    return TimeEntry.eager_load(self.includes).
      where(self.conditions(group.user_ids, self.trackers)).
      order('spent_on ASC')
  end

  def time_entries_for_all_users_in_tracker(tracker)
    return TimeEntry.eager_load(self.includes).
      where(self.conditions(self.users, tracker)).
      order('spent_on ASC')
  end

  def time_entries_for_current_user(project)
    return project.time_entries.
      eager_load(self.includes).
      where(self.conditions(User.current.id, self.trackers)).
      order('spent_on ASC')
  end

  def time_entries_for_current_user_in_tracker(tracker)
    return TimeEntry.eager_load(self.includes).
      where(self.conditions(User.current.id, tracker)).
      order('spent_on ASC')
  end

  def issue_time_entries_for_all_users(issue)
    return issue.time_entries.eager_load(self.includes).
      where(self.conditions(self.users, self.trackers)).
      order('spent_on ASC')
  end

  def issue_time_entries_for_current_user(issue)
    return issue.time_entries.eager_load(self.includes).
      where(self.conditions(User.current.id, self.trackers)).
      order('spent_on ASC')
  end

  def time_entries_for_user(user, trackers, options={})
    extra_conditions = options.delete(:conditions)

    return TimeEntry.eager_load(self.includes).
      where(self.conditions([user], trackers, extra_conditions)).
      order('spent_on ASC')
  end

  def fetch_time_entries_by_project
    self.projects.each do |project|
      logs = []
      users = []
      if User.current.admin?
        # Administrators can see all time entries
        logs = time_entries_for_all_users(project)
        users = logs.collect(&:user).uniq.sort
      elsif User.current.allowed_to_on_single_potentially_archived_project?(:see_project_timesheets, project)
        # Users with the Role and correct permission can see all time entries
        logs = time_entries_for_all_users(project)
        users = logs.collect(&:user).uniq.sort
      elsif User.current.allowed_to_on_single_potentially_archived_project?(:view_time_entries, project) && (self.users.empty? || self.users.include?(User.current.id)) 
        # Users with permission to see their time entries
        logs = time_entries_for_current_user(project)
        users = logs.collect(&:user).uniq.sort
      else
        # Rest can see nothing
      end

      # Append the parent project name
      if project.parent.nil?
        unless logs.empty?
          self.time_entries[project.to_s] = { :logs => logs, :users => users }
        end
      else
        unless logs.empty?
          self.time_entries[project.parent.to_s + ' / ' + project.to_s] = { :logs => logs, :users => users }
        end
      end
    end
  end
  
  def fetch_time_entries_by_group
    groups = Group.where(:id => self.groups)
    groups.each do |group|
      logs = []
      users = []
      if User.current.admin?
        logs = time_entries_for_all_users_in_group(group)
        users = logs.collect(&:user).uniq.sort
      elsif User.current.groups == [group]
        #Users with the Role and correct permission can see all time entries
        logs = time_entries_for_all_users_in_group(group)
        users = logs.collect(&:user).uniq.sort
      else

        #Rest can see nothing
      end
      unless logs.empty?
        self.time_entries[group.name] = { :logs => logs, :users => users }
      end
    end
  end

  def fetch_time_entries_by_user
    self.users.each do |user_id|
      logs = []
      if User.current.admin?
        # Administrators can see all time entries
        logs = time_entries_for_user(user_id, self.trackers)
      elsif User.current.id == user_id
        # Users can see their own their time entries
        logs = time_entries_for_user(user_id, self.trackers)
      elsif User.current.allowed_to_on_single_potentially_archived_project?(:see_project_timesheets, nil, :global => true)
        # User can see project timesheets in at least once place, so
        # fetch the user timelogs for those projects
        logs = time_entries_for_user(user_id, self.trackers, :conditions => Project.allowed_to_condition(User.current, :see_project_timesheets))
      else
        # Rest can see nothing
      end

      unless logs.empty?
        user = User.find_by_id(user_id)
        self.time_entries[user.name] = { :logs => logs }  unless user.nil?
      end
    end
  end
  

  def fetch_time_entries_by_tracker
    trackers = Tracker.where(:id => self.trackers)
    trackers.each do |tracker|
      logs = []
      users = []
      if User.current.admin?
        # Administrators can see all time entries
        logs = time_entries_for_all_users_in_tracker(tracker.id)
      else
        # Users with the Role and correct permission can see all time entries
        logs = time_entries_for_all_users_in_tracker(tracker.id).select do |te|
          project = Project.find(te.project_id)
          User.current.allowed_to_on_single_potentially_archived_project?(:see_project_timesheets, project) || te.user_id == User.current.id
        end
      end
      unless logs.empty?
        users = logs.collect(&:user).uniq.sort
        self.time_entries[tracker.name] = { :logs => logs, :users => users }
      end
    end
  end


  #   project => { :users => [users shown in logs],
  #                :issues =>
  #                  { issue => {:logs => [time entries],
  #                    issue => {:logs => [time entries],
  #                    issue => {:logs => [time entries]}
  #
  def fetch_time_entries_by_issue
    self.projects.each do |project|
      logs = []
      users = []
      project.issues.each do |issue|
        if User.current.admin?
          # Administrators can see all time entries
          logs << issue_time_entries_for_all_users(issue)
        elsif User.current.allowed_to_on_single_potentially_archived_project?(:see_project_timesheets, project)
          # Users with the Role and correct permission can see all time entries
          logs << issue_time_entries_for_all_users(issue)
        elsif User.current.allowed_to_on_single_potentially_archived_project?(:view_time_entries, project) && (self.users.empty? || self.users.include?(User.current.id) )
          # Users with permission to see their time entries
          logs << issue_time_entries_for_current_user(issue)
        else
          # Rest can see nothing
        end
      end

      logs.flatten! if logs.respond_to?(:flatten!)
      logs.uniq! if logs.respond_to?(:uniq!)

      unless logs.empty?
        users << logs.collect(&:user).uniq.sort


        issues = logs.collect(&:issue).uniq
        issue_logs = { }
        issues.each do |issue|
          issue_logs[issue] = logs.find_all {|time_log| time_log.issue == issue } # TimeEntry is for this issue
        end

        # TODO: TE without an issue

        self.time_entries[project] = { :issues => issue_logs, :users => users}
      end
    end
  end

  
  def fetch_time_entries_by_date

 
    #---------------------------------------------------
    
    logs = []

    #           extra_conditions = 'GROUP_BY spent_on'
    logs = TimeEntry.eager_load(self.includes).where(self.conditions(self.users, self.trackers))
       
       
    unless logs.empty?
   
        
      logs.each do |log|
        date=log.spent_on
        logs_to_return=[]
        logs.each do |log2return|
          if log2return.spent_on==date
            logs_to_return << log2return
          end
        end
     
           

        self.time_entries[date] = { :logs => logs_to_return }
      end
    end

  end

  def l(*args)
    I18n.t(*args)
  end
end
