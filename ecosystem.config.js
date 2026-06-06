module.exports = {
  apps: [{
    name: 'battle_bot',
    script: 'main.rb',
    interpreter: 'ruby',
    cwd: '/root/mastodon_bots/battle_bot',
    autorestart: true,
    max_restarts: 50,
    min_uptime: '5s',
    max_memory_restart: '500M',
    restart_delay: 1000,
    exp_backoff_restart_delay: 100,
    error_file: '/root/mastodon_bots/battle_bot/logs/error.log',
    out_file: '/root/mastodon_bots/battle_bot/logs/out.log',
    log_date_format: 'YYYY-MM-DD HH:mm:ss',
    merge_logs: true,
    env: {
      NODE_ENV: 'production',
      TZ: 'Asia/Seoul'
    },
    watch: false,
    ignore_watch: ['logs', 'node_modules'],
    cron_restart: '0 4 * * *',
    instances: 1,
    exec_mode: 'fork'
  }]
};
