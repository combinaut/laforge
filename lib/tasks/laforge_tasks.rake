namespace :laforge do
  desc "Polls the commit entries table for changes to sync to production"
  task :auto_sync, [:delay] => :environment do |t, args|
    delay = args[:delay].present? ? args[:delay].to_i : 5.seconds
    LaForge::Staging::Synchronizer.auto_sync(delay)
  end

  desc "Syncs records that don't need confirmation to production"
  task :sync, [:limit] => :environment do |t, args|
    limit = args[:limit].present? ? args[:limit].to_i : nil
    LaForge::Staging::Synchronizer.sync(limit)
  end

  desc "Syncs all records to production, including those that require confirmation"
  task :sync_all => :environment do
    LaForge::Staging::Synchronizer.sync_all
  end

  # Enhance the regular tasks to run on both staging and production databases
  def rake_both_databases(task, laforge_task = task.gsub(':','_'))
    task(laforge_task => :environment) do
      LaForge::Database.each do |connection_name|
        LaForge::Connection.with_production_writes do
          puts "#{connection_name}"
          Rake::Task[task].reenable
          Rake::Task[task].invoke
        end
      end
      Rake::Task[task].clear
    end

    # Enhance the original task to run the laforge_task as a prerequisite
    Rake::Task[task].enhance(["laforge:#{laforge_task}"])
  end

  rake_both_databases('db:migrate')
  rake_both_databases('db:rollback')
  rake_both_databases('db:test:load_structure')
end
