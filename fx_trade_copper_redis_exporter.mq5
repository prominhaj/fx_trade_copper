//+------------------------------------------------------------------+
//|                                fx_trade_copper_redis_exporter.mq5 |
//|                          Copyright 2024-2026, FX Trade Copper     |
//|                                         https://www.allanmaug.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024-2026, FX Trade Copper"
#property link      "https://www.allanmaug.com"
#property version   "1.00"
#property strict

#include "fx_trade_copper_redis_module.mqh"

input string ChannelId = "default";
input int TimerIntervalMs = 1000;
input bool VerboseLogs = true;
input bool EnableRedisHttpExport = true;
input string RedisHttpBaseUrl = "";
input string RedisHttpEndpointPath = "/api/v1/mt5/redis-sync";
input int RedisHttpTimeoutMs = 5000;
input int RedisHttpPublishIntervalSec = 60;
input bool RedisHttpPublishOnTradeEvents = true;
input string RedisHttpAuthHeaderName = "Authorization";
input string RedisHttpAuthToken = "";
input bool RedisHttpUseBearerToken = true;
input bool RedisHttpAllowInsecureHttp = false;
input bool RedisHttpIncludeOpenPositions = true;
input bool RedisHttpIncludePendingOrders = true;
input bool RedisHttpIncludeTradeHistory = true;
input int RedisHttpTradeHistoryDays = 35;
input int RedisHttpMaxDealsPerPush = 200;
input string RedisHttpCustomFromDate = "";
input string RedisHttpCustomToDate = "";

CRedisHttpExporter g_redis_exporter;
string g_channel_key="";

bool IsWhiteSpace(const int ch)
  {
   return ch==' ' || ch=='\t' || ch=='\r' || ch=='\n';
  }

string TrimString(const string value)
  {
   int start=0;
   int finish=StringLen(value)-1;
   while(start<=finish && IsWhiteSpace(StringGetCharacter(value,start)))
      start++;
   while(finish>=start && IsWhiteSpace(StringGetCharacter(value,finish)))
      finish--;
   if(start>finish)
      return "";
   return StringSubstr(value,start,finish-start+1);
  }

string SanitizeIdentifier(const string value)
  {
   string cleaned="";
   int length=StringLen(value);
   for(int i=0;i<length;i++)
     {
      int ch=StringGetCharacter(value,i);
      if((ch>='a' && ch<='z') || (ch>='A' && ch<='Z') || (ch>='0' && ch<='9') || ch=='-' || ch=='_' || ch=='.')
         cleaned+=StringSubstr(value,i,1);
      else
         cleaned+="_";
     }
   if(cleaned=="")
      cleaned="default";
   return cleaned;
  }

void LoadRedisHttpExportConfig(RedisHttpExportConfig &config)
  {
   config.enabled=EnableRedisHttpExport;
   config.base_url=RedisHttpBaseUrl;
   config.endpoint_path=RedisHttpEndpointPath;
   config.timeout_ms=RedisHttpTimeoutMs;
   config.publish_interval_sec=RedisHttpPublishIntervalSec;
   config.publish_on_trade_events=RedisHttpPublishOnTradeEvents;
   config.auth_header_name=RedisHttpAuthHeaderName;
   config.auth_token=RedisHttpAuthToken;
   config.use_bearer_token=RedisHttpUseBearerToken;
   config.allow_insecure_http=RedisHttpAllowInsecureHttp;
   config.include_open_positions=RedisHttpIncludeOpenPositions;
   config.include_pending_orders=RedisHttpIncludePendingOrders;
   config.include_trade_history=RedisHttpIncludeTradeHistory;
   config.trade_history_days=RedisHttpTradeHistoryDays;
   config.max_deals_per_push=RedisHttpMaxDealsPerPush;
   config.custom_from_date=RedisHttpCustomFromDate;
   config.custom_to_date=RedisHttpCustomToDate;
   config.verbose_logs=VerboseLogs;
   config.log_prefix="FXTradeCopperRedis";
   config.ea_name="FX Trade Copper Redis Exporter";
   config.ea_version="1.00";
   config.mode_name="EXPORTER";
   config.channel_id=g_channel_key;
   config.copy_positions=false;
   config.copy_pending_orders=false;
   config.copy_stop_loss=false;
   config.copy_take_profit=false;
   config.copy_expirations=false;
   config.volume_multiplier=1.0;
   config.enable_slave_time_schedule=false;
   config.simple_lot_window=false;
  }

int OnInit()
  {
   g_channel_key=SanitizeIdentifier(TrimString(ChannelId));

   if(TimerIntervalMs<100)
      return INIT_PARAMETERS_INCORRECT;

   RedisHttpExportConfig redis_export_config;
   LoadRedisHttpExportConfig(redis_export_config);
   if(!g_redis_exporter.Initialize(redis_export_config))
      return INIT_PARAMETERS_INCORRECT;

   EventSetMillisecondTimer(TimerIntervalMs);
   if(VerboseLogs)
      Print("[FXTradeCopperRedis] Initialized. channel=",g_channel_key,", timer_ms=",TimerIntervalMs);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

void OnTimer()
  {
   g_redis_exporter.MaybePublish();
  }

void OnTrade()
  {
   if(EnableRedisHttpExport && RedisHttpPublishOnTradeEvents)
      g_redis_exporter.QueuePublish();
  }

void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
  {
   if(EnableRedisHttpExport && RedisHttpPublishOnTradeEvents)
      g_redis_exporter.QueuePublish();
  }

