class UserController < ApplicationController
  layout :choose_layout

  before_filter :disable_terms_redirect, :only => [:terms, :save, :logout, :api_details]
  before_filter :authorize, :only => [:api_details, :api_gpx_files]
  before_filter :authorize_web, :except => [:api_details, :api_gpx_files]
  before_filter :set_locale, :except => [:api_details, :api_gpx_files]
  before_filter :require_user, :only => [:account, :go_public, :make_friend, :remove_friend]
  before_filter :check_database_readable, :except => [:api_details, :api_gpx_files]
  before_filter :check_database_writable, :only => [:login, :new, :account, :go_public, :make_friend, :remove_friend]
  before_filter :check_api_readable, :only => [:api_details, :api_gpx_files]
  before_filter :require_allow_read_prefs, :only => [:api_details]
  before_filter :require_allow_read_gpx, :only => [:api_gpx_files]
  before_filter :require_cookies, :only => [:login, :confirm]
  before_filter :require_administrator, :only => [:set_status, :delete, :list]
  before_filter :lookup_this_user, :only => [:set_status, :delete]

  filter_parameter_logging :password, :pass_crypt, :pass_crypt_confirmation

  cache_sweeper :user_sweeper, :only => [:account, :set_status, :delete], :unless => STATUS == :database_offline

  def terms
    @legale = params[:legale] || OSM.IPToCountry(request.remote_ip) || DEFAULT_LEGALE
    @text = OSM.legal_text_for_country(@legale)

    if request.xhr?
      render :update do |page|
        page.replace_html "contributorTerms", :partial => "terms"
      end
    else
      @title = t 'user.terms.title'
      @user = User.new(params[:user]) if params[:user]

      if @user
        if @user.invalid?
          if @user.new_record?
            render :action => :new
          else
            flash[:errors] = @user.errors
            redirect_to :action => :account, :display_name => @user.display_name
          end
        elsif @user.terms_agreed?
          redirect_to :action => :account, :display_name => @user.display_name
        end
      else
        redirect_to :action => :login, :referer => request.request_uri
      end
    end
  end

  def save
    @title = t 'user.new.title'

    if Acl.find_by_address(request.remote_ip, :conditions => {:k => "no_account_creation"})
      render :action => 'new'
    elsif params[:decline]
      if @user
        @user.terms_seen = true

        if @user.save
          flash[:notice] = t 'user.new.terms declined', :url => t('user.new.terms declined url')
        end

        if params[:referer]
          redirect_to params[:referer]
        else
          redirect_to :action => :account, :display_name => @user.display_name
        end
      else
        redirect_to t('user.terms.declined')
      end
    elsif @user
      if !@user.terms_agreed?
        @user.consider_pd = params[:user][:consider_pd]
        @user.terms_agreed = Time.now.getutc
        @user.terms_seen = true
        if @user.save
          flash[:notice] = t 'user.new.terms accepted'
        end
      end

      if params[:referer]
        redirect_to params[:referer]
      else
        redirect_to :action => :account, :display_name => @user.display_name
      end
    else
      @user = User.new(params[:user])

      @user.status = "pending"
      @user.data_public = true
      @user.description = "" if @user.description.nil?
      @user.creation_ip = request.remote_ip
      @user.languages = request.user_preferred_languages
      @user.terms_agreed = Time.now.getutc
      @user.terms_seen = true
      
      if @user.save
        flash[:notice] = t 'user.new.flash create success message', :email => @user.email
        Notifier.deliver_signup_confirm(@user, @user.tokens.create(:referer => params[:referer]))
        session[:token] = @user.tokens.create.token
        redirect_to :action => 'login', :referer => params[:referer]
      else
        render :action => 'new', :referer => params[:referer]
      end
    end
  end

  def account
    @title = t 'user.account.title'
    @tokens = @user.oauth_tokens.find :all, :conditions => 'oauth_tokens.invalidated_at is null and oauth_tokens.authorized_at is not null'

    if params[:user] and params[:user][:display_name] and params[:user][:description]
      @user.display_name = params[:user][:display_name]
      @user.new_email = params[:user][:new_email]

      if params[:user][:pass_crypt].length > 0 or params[:user][:pass_crypt_confirmation].length > 0
        @user.pass_crypt = params[:user][:pass_crypt]
        @user.pass_crypt_confirmation = params[:user][:pass_crypt_confirmation]
      end

      @user.description = params[:user][:description]
      @user.languages = params[:user][:languages].split(",")

      case params[:image_action]
        when "new" then @user.image = params[:user][:image]
        when "delete" then @user.image = nil
      end

      @user.home_lat = params[:user][:home_lat]
      @user.home_lon = params[:user][:home_lon]

      if params[:user][:preferred_editor] == "default"
        @user.preferred_editor = nil
      else
        @user.preferred_editor = params[:user][:preferred_editor]
      end

      if @user.save
        set_locale

        if @user.new_email.nil? or @user.new_email.empty?
          flash[:notice] = t 'user.account.flash update success'
        else
          flash[:notice] = t 'user.account.flash update success confirm needed'

          begin
            Notifier.deliver_email_confirm(@user, @user.tokens.create)
          rescue
            # Ignore errors sending email
          end
        end

        redirect_to :action => "account", :display_name => @user.display_name
      end
    else
      if flash[:errors]
        flash[:errors].each do |attr,msg|
          attr = "new_email" if attr == "email" and !@user.new_email.nil?
          @user.errors.add(attr,msg)
        end
      end
    end
  end

  def go_public
    @user.data_public = true
    @user.save
    flash[:notice] = t 'user.go_public.flash success'
    redirect_to :controller => 'user', :action => 'account', :display_name => @user.display_name
  end

  def lost_password
    @title = t 'user.lost_password.title'

    if params[:user] and params[:user][:email]
      user = User.find_by_email(params[:user][:email], :conditions => {:status => ["pending", "active", "confirmed"]})

      if user
        token = user.tokens.create
        Notifier.deliver_lost_password(user, token)
        flash[:notice] = t 'user.lost_password.notice email on way'
        redirect_to :action => 'login'
      else
        flash.now[:error] = t 'user.lost_password.notice email cannot find'
      end
    end
  end

  def reset_password
    @title = t 'user.reset_password.title'

    if params[:token]
      token = UserToken.find_by_token(params[:token])

      if token
        @user = token.user

        if params[:user]
          @user.pass_crypt = params[:user][:pass_crypt]
          @user.pass_crypt_confirmation = params[:user][:pass_crypt_confirmation]
          @user.status = "active" if @user.status == "pending"
          @user.email_valid = true

          if @user.save
            token.destroy
            flash[:notice] = t 'user.reset_password.flash changed'
            redirect_to :action => 'login'
          end
        end
      else
        flash[:error] = t 'user.reset_password.flash token bad'
        redirect_to :action => 'lost_password'
      end
    end
  end

  def new
    @title = t 'user.new.title'

    # The user is logged in already, so don't show them the signup
    # page, instead send them to the home page
    redirect_to :controller => 'site', :action => 'index' if session[:user]
  end

  def login
    @title = t 'user.login.title'

    if params[:user]
      email_or_display_name = params[:user][:email]
      pass = params[:user][:password]
      user = User.authenticate(:username => email_or_display_name, :password => pass)

      if user
        session[:user] = user.id
        session_expires_after 1.month if params[:remember_me]

        target = params[:referer] || url_for(:controller => :site, :action => :index)

        # The user is logged in, so decide where to send them:
        #
        # - If they haven't seen the contributor terms, send them there.
        # - If they have a block on them, show them that.
        # - If they were referred to the login, send them back there.
        # - Otherwise, send them to the home page.
        if REQUIRE_TERMS_SEEN and not user.terms_seen
          redirect_to :controller => :user, :action => :terms, :referer => target
        elsif user.blocked_on_view
          redirect_to user.blocked_on_view, :referer => target
        else
          redirect_to target
        end
      elsif user = User.authenticate(:username => email_or_display_name, :password => pass, :pending => true)
        flash.now[:error] = t 'user.login.account not active', :reconfirm => url_for(:action => 'confirm_resend', :display_name => user.display_name)
      elsif User.authenticate(:username => email_or_display_name, :password => pass, :suspended => true)
        webmaster = link_to t('user.login.webmaster'), "mailto:webmaster@openstreetmap.org"
        flash.now[:error] = t 'user.login.account suspended', :webmaster => webmaster
      else
        flash.now[:error] = t 'user.login.auth failure'
      end
    elsif flash[:notice].nil?
      flash.now[:notice] =  t 'user.login.notice'
    end
  end

  def logout
    @title = t 'user.logout.title'

    if params[:session] == request.session_options[:id]
      if session[:token]
        token = UserToken.find_by_token(session[:token])
        if token
          token.destroy
        end
        session[:token] = nil
      end
      session[:user] = nil
      session_expires_automatically
      if params[:referer]
        redirect_to params[:referer]
      else
        redirect_to :controller => 'site', :action => 'index'
      end
    end
  end

  def confirm
    if request.post?
      if token = UserToken.find_by_token(params[:confirm_string])
        if token.user.active?
          flash[:error] = t('user.confirm.already active')
          redirect_to :action => 'login'
        else
          user = token.user
          user.status = "active"
          user.email_valid = true
          user.save!
          referer = token.referer
          token.destroy

          if session[:token] 
            token = UserToken.find_by_token(session[:token])
            session.delete(:token)
          else
            token = nil
          end

          if token.nil? or token.user != user
            flash[:notice] = t('user.confirm.success')
            redirect_to :action => :login, :referer => referer
          else
            token.destroy

            session[:user] = user.id

            if referer.nil?
              flash[:notice] = t('user.confirm.success') + "<br /><br />" + t('user.confirm.before you start')
              redirect_to :action => :account, :display_name => user.display_name
            else
              flash[:notice] = t('user.confirm.success')
              redirect_to referer
            end
          end
        end
      else
        user = User.find_by_display_name(params[:display_name])

        if user and user.active?
          flash[:error] = t('user.confirm.already active')
        elsif user
          flash[:error] = t('user.confirm.unknown token') + t('user.confirm.reconfirm', :reconfirm => url_for(:action => 'confirm_resend', :display_name => params[:display_name]))
        else
          flash[:error] = t('user.confirm.unknown token')
        end

        redirect_to :action => 'login'
      end
    end
  end

  def confirm_resend
    if user = User.find_by_display_name(params[:display_name])
      Notifier.deliver_signup_confirm(user, user.tokens.create)
      flash[:notice] = t 'user.confirm_resend.success', :email => user.email
    else
      flash[:notice] = t 'user.confirm_resend.failure', :name => params[:display_name]
    end

    redirect_to :action => 'login'
  end

  def confirm_email
    if request.post?
      token = UserToken.find_by_token(params[:confirm_string])
      if token and token.user.new_email?
        @user = token.user
        @user.email = @user.new_email
        @user.new_email = nil
        @user.email_valid = true
        if @user.save
          flash[:notice] = t 'user.confirm_email.success'
        else
          flash[:errors] = @user.errors
        end
        token.destroy
        session[:user] = @user.id
        redirect_to :action => 'account', :display_name => @user.display_name
      else
        flash[:error] = t 'user.confirm_email.failure'
        redirect_to :action => 'account', :display_name => @user.display_name
      end
    end
  end

  def api_gpx_files
    doc = OSM::API.new.get_xml_doc
    @user.traces.each do |trace|
      doc.root << trace.to_xml_node() if trace.public? or trace.user == @user
    end
    render :text => doc.to_s, :content_type => "text/xml"
  end

  def view
    @this_user = User.find_by_display_name(params[:display_name])

    if @this_user and
       (@this_user.visible? or (@user and @user.administrator?))
      @title = @this_user.display_name
    else
      @title = t 'user.no_such_user.title'
      @not_found_user = params[:display_name]
      render :action => 'no_such_user', :status => :not_found
    end
  end

  def make_friend
    if params[:display_name]
      name = params[:display_name]
      new_friend = User.find_by_display_name(name, :conditions => {:status => ["active", "confirmed"]})
      friend = Friend.new
      friend.user_id = @user.id
      friend.friend_user_id = new_friend.id
      unless @user.is_friends_with?(new_friend)
        if friend.save
          flash[:notice] = t 'user.make_friend.success', :name => name
          Notifier.deliver_friend_notification(friend)
        else
          friend.add_error(t('user.make_friend.failed', :name => name))
        end
      else
        flash[:warning] = t 'user.make_friend.already_a_friend', :name => name
      end

      if params[:referer]
        redirect_to params[:referer]
      else
        redirect_to :controller => 'user', :action => 'view'
      end
    end
  end

  def remove_friend
    if params[:display_name]
      name = params[:display_name]
      friend = User.find_by_display_name(name, :conditions => {:status => ["active", "confirmed"]})
      if @user.is_friends_with?(friend)
        Friend.delete_all "user_id = #{@user.id} AND friend_user_id = #{friend.id}"
        flash[:notice] = t 'user.remove_friend.success', :name => friend.display_name
      else
        flash[:error] = t 'user.remove_friend.not_a_friend', :name => friend.display_name
      end

      if params[:referer]
        redirect_to params[:referer]
      else
        redirect_to :controller => 'user', :action => 'view'
      end
    end
  end

  ##
  # sets a user's status
  def set_status
    @this_user.update_attributes(:status => params[:status])
    redirect_to :controller => 'user', :action => 'view', :display_name => params[:display_name]
  end

  ##
  # delete a user, marking them as deleted and removing personal data
  def delete
    @this_user.delete
    redirect_to :controller => 'user', :action => 'view', :display_name => params[:display_name]
  end

  ##
  # display a list of users matching specified criteria
  def list
    if request.post?
      ids = params[:user].keys.collect { |id| id.to_i }

      User.update_all("status = 'confirmed'", :id => ids) if params[:confirm]
      User.update_all("status = 'deleted'", :id => ids) if params[:hide]

      redirect_to url_for(:status => params[:status], :ip => params[:ip], :page => params[:page])
    else
      conditions = Hash.new
      conditions[:status] = params[:status] if params[:status]
      conditions[:creation_ip] = params[:ip] if params[:ip]

      @user_pages, @users = paginate(:users,
                                     :conditions => conditions,
                                     :order => :id,
                                     :per_page => 50)
    end
  end

private

  ##
  # require that the user is a administrator, or fill out a helpful error message
  # and return them to the user page.
  def require_administrator
    if @user and not @user.administrator?
      flash[:error] = t('user.filter.not_an_administrator')

      if params[:display_name]
        redirect_to :controller => 'user', :action => 'view', :display_name => params[:display_name]
      else
        redirect_to :controller => 'user', :action => 'login', :referer => request.request_uri
      end
    elsif not @user
      redirect_to :controller => 'user', :action => 'login', :referer => request.request_uri
    end
  end

  ##
  # ensure that there is a "this_user" instance variable
  def lookup_this_user
    @this_user = User.find_by_display_name(params[:display_name])
  rescue ActiveRecord::RecordNotFound
    redirect_to :controller => 'user', :action => 'view', :display_name => params[:display_name] unless @this_user
  end

  ##
  # Choose the layout to use. See
  # https://rails.lighthouseapp.com/projects/8994/tickets/5371-layout-with-onlyexcept-options-makes-other-actions-render-without-layouts
  def choose_layout
    oauth_url = url_for(:controller => :oauth, :action => :oauthorize, :only_path => true)

    if [ 'api_details' ].include? action_name
      nil
    elsif params[:referer] and URI.parse(params[:referer]).path == oauth_url
      'slim'
    else
      'site'
    end
  end

  ##
  #
  def disable_terms_redirect
    # this is necessary otherwise going to the user terms page, when 
    # having not agreed already would cause an infinite redirect loop.
    # it's .now so that this doesn't propagate to other pages.
    flash.now[:skip_terms] = true
  end
end
