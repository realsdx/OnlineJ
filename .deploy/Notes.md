## Random Notes

1. bundle install
2. gem install sidetiq
3. bundle install

These commnads should run without any errors.

For Local prod settings set : RAILS_SERVE_STATIC_FILES=true
                              SECRET_KEY_BASE=<somekey>

4. Updated devise due to Ruby syntax issue with `bundle update devise`
5. Manually changed the `rack` version to `2.0.7`


### Steps used to deploy

1. rvm install ruby-2.6.5
2. rvm use ruby-2.6.5@OnlineJ --create
3. gem install bunlder _[Verify installed bundler with `which bundle`]_
4. bundle install
5. gem install sidetiq
6. bundle install
    _[Checked version of rack and devise (unchanged)]_
7. bundle exec rake judje:init
8. Eet evnvironment variables   - `RAILS_SERVE_STATIC_FILES`
                                - `RAILS_DEBUG`
                                - `SECRET_KEY_BASE`
                                - `RAILS_ENV`
                                
9. RAILS_ENV=production rake assets:precompile
10. bundle exec puma -C config/puma.prod.rb -tcp://0.0.0.0:3000 -d
11. bundle exec sidekiq -e production -d