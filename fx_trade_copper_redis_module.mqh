struct RedisHttpExportConfig
  {
   bool enabled;
   string base_url;
   string endpoint_path;
   int timeout_ms;
   int publish_interval_sec;
   bool publish_on_trade_events;
   string auth_header_name;
   string auth_token;
   bool use_bearer_token;
   bool allow_insecure_http;
   bool include_open_positions;
   bool include_pending_orders;
   bool include_trade_history;
   int trade_history_days;
   int max_deals_per_push;
   string custom_from_date;
   string custom_to_date;
   bool verbose_logs;
   string log_prefix;
   string ea_name;
   string ea_version;
   string mode_name;
   string channel_id;
   bool copy_positions;
   bool copy_pending_orders;
   bool copy_stop_loss;
   bool copy_take_profit;
   bool copy_expirations;
   double volume_multiplier;
   bool enable_slave_time_schedule;
   bool simple_lot_window;
  };

struct RedisPnlRangeAccumulator
  {
   datetime from_time;
   datetime to_time;
   double profit;
   double commission;
   double swap;
   double fee;
   double net;
   double volume;
   int deal_count;
   int win_count;
   int loss_count;
  };

class CRedisHttpExporter
  {
private:
   RedisHttpExportConfig m_config;
   datetime         m_last_publish;
   bool             m_force_publish;
   string           m_last_status;
   string           m_endpoint_url;
   bool             m_has_custom_range;
   datetime         m_custom_from;
   datetime         m_custom_to;

   bool             IsWhiteSpace(const int ch)
     {
      return ch==' ' || ch=='\t' || ch=='\r' || ch=='\n';
     }

   string           TrimString(const string value)
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

   string           ToLowerAscii(const string value)
     {
      string result="";
      int length=StringLen(value);
      for(int i=0;i<length;i++)
        {
         int ch=StringGetCharacter(value,i);
         if(ch>='A' && ch<='Z')
            ch+=32;
         result+=CharToString((uchar)ch);
        }
      return result;
     }

   string           ReplaceString(const string value,const string search,const string replacement)
     {
      string result=value;
      int index=StringFind(result,search,0);
      int search_length=StringLen(search);
      while(index>=0)
        {
         result=StringSubstr(result,0,index)+replacement+StringSubstr(result,index+search_length);
         index=StringFind(result,search,index+StringLen(replacement));
        }
      return result;
     }

   bool             StartsWithText(const string value,const string prefix)
     {
      return StringSubstr(value,0,StringLen(prefix))==prefix;
     }

   string           TrimTrailingSlashes(const string value)
     {
      string result=value;
      while(StringLen(result)>0)
        {
         int ch=StringGetCharacter(result,StringLen(result)-1);
         if(ch!='/' && ch!='\\')
            break;
         result=StringSubstr(result,0,StringLen(result)-1);
        }
      return result;
     }

   string           EnsureLeadingSlash(const string value)
     {
      if(value=="")
         return "";
      if(StringGetCharacter(value,0)=='/')
         return value;
      return "/"+value;
     }

   string           JoinUrl(const string base_url,const string path)
     {
      string trimmed_base=TrimTrailingSlashes(TrimString(base_url));
      string normalized_path=EnsureLeadingSlash(TrimString(path));
      if(trimmed_base=="")
         return normalized_path;
      if(normalized_path=="")
         return trimmed_base;
      return trimmed_base+normalized_path;
     }

   string           JsonEscape(const string value)
     {
      string escaped="";
      int length=StringLen(value);
      for(int i=0;i<length;i++)
        {
         int ch=StringGetCharacter(value,i);
         if(ch=='\\')
            escaped+="\\\\";
         else if(ch=='\"')
            escaped+="\\\"";
         else if(ch=='\r')
            escaped+="\\r";
         else if(ch=='\n')
            escaped+="\\n";
         else if(ch=='\t')
            escaped+="\\t";
         else
            escaped+=StringSubstr(value,i,1);
        }
      return escaped;
     }

   string           JsonString(const string value)
     {
      return "\""+JsonEscape(value)+"\"";
     }

   string           JsonBool(const bool value)
     {
      return value ? "true" : "false";
     }

   string           LongToText(const long value)
     {
      return StringFormat("%I64d",value);
     }

   string           ULongToText(const ulong value)
     {
      return StringFormat("%I64u",value);
     }

   string           DateTimeToIsoText(const datetime value)
     {
      MqlDateTime parts={};
      if(!TimeToStruct(value,parts))
         return "";
      return StringFormat("%04d-%02d-%02dT%02d:%02d:%02d",
                          parts.year,
                          parts.mon,
                          parts.day,
                          parts.hour,
                          parts.min,
                          parts.sec);
     }

   datetime         StartOfDay(const datetime value)
     {
      MqlDateTime parts={};
      if(!TimeToStruct(value,parts))
         return value;
      parts.hour=0;
      parts.min=0;
      parts.sec=0;
      return StructToTime(parts);
     }

   bool             ParseDateInput(const string text,const bool end_of_day,datetime &value)
     {
      value=0;
      string trimmed=TrimString(text);
      if(trimmed=="")
         return false;

      string normalized=ReplaceString(trimmed,"/","-");
      normalized=ReplaceString(normalized,".","-");

      string parts[];
      if(StringSplit(normalized,'-',parts)!=3)
         return false;

      int year=(int)StringToInteger(parts[0]);
      int month=(int)StringToInteger(parts[1]);
      int day=(int)StringToInteger(parts[2]);
      if(year<1970 || month<1 || month>12 || day<1 || day>31)
         return false;

      MqlDateTime dt={};
      dt.year=year;
      dt.mon=month;
      dt.day=day;
      dt.hour=end_of_day ? 23 : 0;
      dt.min=end_of_day ? 59 : 0;
      dt.sec=end_of_day ? 59 : 0;
      value=StructToTime(dt);
      return value>0;
     }

   bool             IsSecureHttpUrl(const string url)
     {
      return StartsWithText(ToLowerAscii(TrimString(url)),"https://");
     }

   void             LogMessage(const string message)
     {
      if(!m_config.verbose_logs)
         return;
      string prefix=(TrimString(m_config.log_prefix)=="") ? "FXTradeCopperRedis" : TrimString(m_config.log_prefix);
      Print("[",prefix,"] ",message);
     }

   bool             OrderTypeIsPending(const ENUM_ORDER_TYPE order_type)
     {
      return order_type==ORDER_TYPE_BUY_LIMIT ||
             order_type==ORDER_TYPE_SELL_LIMIT ||
             order_type==ORDER_TYPE_BUY_STOP ||
             order_type==ORDER_TYPE_SELL_STOP ||
             order_type==ORDER_TYPE_BUY_STOP_LIMIT ||
             order_type==ORDER_TYPE_SELL_STOP_LIMIT;
     }

   bool             IsTradeDealType(const ENUM_DEAL_TYPE deal_type)
     {
      return deal_type==DEAL_TYPE_BUY ||
             deal_type==DEAL_TYPE_SELL ||
             deal_type==DEAL_TYPE_BUY_CANCELED ||
             deal_type==DEAL_TYPE_SELL_CANCELED;
     }

   void             ResetPnlRange(RedisPnlRangeAccumulator &range,const datetime from_time,const datetime to_time)
     {
      range.from_time=from_time;
      range.to_time=to_time;
      range.profit=0.0;
      range.commission=0.0;
      range.swap=0.0;
      range.fee=0.0;
      range.net=0.0;
      range.volume=0.0;
      range.deal_count=0;
      range.win_count=0;
      range.loss_count=0;
     }

   bool             TimeInRange(const datetime value,const RedisPnlRangeAccumulator &range)
     {
      return value>=range.from_time && value<=range.to_time;
     }

   void             AccumulatePnlRange(RedisPnlRangeAccumulator &range,const datetime deal_time,const double volume,const double profit,const double commission,const double swap,const double fee)
     {
      if(!TimeInRange(deal_time,range))
         return;

      double net=profit+commission+swap+fee;
      range.profit+=profit;
      range.commission+=commission;
      range.swap+=swap;
      range.fee+=fee;
      range.net+=net;
      range.volume+=volume;
      range.deal_count++;
      if(net>0.0)
         range.win_count++;
      else if(net<0.0)
         range.loss_count++;
     }

   string           BuildPnlRangeJson(const string label,const RedisPnlRangeAccumulator &range)
     {
      return JsonString(label)+":"+
             "{"+
             "\"from\":"+LongToText((long)range.from_time)+","+
             "\"to\":"+LongToText((long)range.to_time)+","+
             "\"from_text\":"+JsonString(DateTimeToIsoText(range.from_time))+","+
             "\"to_text\":"+JsonString(DateTimeToIsoText(range.to_time))+","+
             "\"deal_count\":"+IntegerToString(range.deal_count)+","+
             "\"win_count\":"+IntegerToString(range.win_count)+","+
             "\"loss_count\":"+IntegerToString(range.loss_count)+","+
             "\"volume\":"+DoubleToString(range.volume,2)+","+
             "\"profit\":"+DoubleToString(range.profit,2)+","+
             "\"commission\":"+DoubleToString(range.commission,2)+","+
             "\"swap\":"+DoubleToString(range.swap,2)+","+
             "\"fee\":"+DoubleToString(range.fee,2)+","+
             "\"net\":"+DoubleToString(range.net,2)+
             "}";
     }

   string           BuildOpenPositionsJson()
     {
      if(!m_config.include_open_positions)
         return "[]";

      string json="[";
      bool first=true;
      for(int i=0;i<PositionsTotal();i++)
        {
         ulong ticket=PositionGetTicket(i);
         if(ticket==0 || !PositionSelectByTicket(ticket))
            continue;

         if(!first)
            json+=",";
         first=false;

         json+="{"+
               "\"ticket\":"+ULongToText(ticket)+","+
               "\"symbol\":"+JsonString(PositionGetString(POSITION_SYMBOL))+","+
               "\"type\":"+JsonString(EnumToString((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)))+","+
               "\"volume\":"+DoubleToString(PositionGetDouble(POSITION_VOLUME),2)+","+
               "\"price_open\":"+DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN),8)+","+
               "\"price_current\":"+DoubleToString(PositionGetDouble(POSITION_PRICE_CURRENT),8)+","+
               "\"sl\":"+DoubleToString(PositionGetDouble(POSITION_SL),8)+","+
               "\"tp\":"+DoubleToString(PositionGetDouble(POSITION_TP),8)+","+
               "\"profit\":"+DoubleToString(PositionGetDouble(POSITION_PROFIT),2)+","+
               "\"swap\":"+DoubleToString(PositionGetDouble(POSITION_SWAP),2)+","+
               "\"magic\":"+LongToText(PositionGetInteger(POSITION_MAGIC))+","+
               "\"comment\":"+JsonString(PositionGetString(POSITION_COMMENT))+
               "}";
        }
      json+="]";
      return json;
     }

   string           BuildPendingOrdersJson()
     {
      if(!m_config.include_pending_orders)
         return "[]";

      string json="[";
      bool first=true;
      for(int i=0;i<OrdersTotal();i++)
        {
         ulong ticket=OrderGetTicket(i);
         if(ticket==0 || !OrderSelect(ticket))
            continue;

         ENUM_ORDER_TYPE order_type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         if(!OrderTypeIsPending(order_type))
            continue;

         if(!first)
            json+=",";
         first=false;

         json+="{"+
               "\"ticket\":"+ULongToText(ticket)+","+
               "\"symbol\":"+JsonString(OrderGetString(ORDER_SYMBOL))+","+
               "\"type\":"+JsonString(EnumToString(order_type))+","+
               "\"volume\":"+DoubleToString(OrderGetDouble(ORDER_VOLUME_INITIAL),2)+","+
               "\"price\":"+DoubleToString(OrderGetDouble(ORDER_PRICE_OPEN),8)+","+
               "\"stop_limit\":"+DoubleToString(OrderGetDouble(ORDER_PRICE_STOPLIMIT),8)+","+
               "\"sl\":"+DoubleToString(OrderGetDouble(ORDER_SL),8)+","+
               "\"tp\":"+DoubleToString(OrderGetDouble(ORDER_TP),8)+","+
               "\"expiration\":"+LongToText((long)OrderGetInteger(ORDER_TIME_EXPIRATION))+","+
               "\"magic\":"+LongToText(OrderGetInteger(ORDER_MAGIC))+","+
               "\"comment\":"+JsonString(OrderGetString(ORDER_COMMENT))+
               "}";
        }
      json+="]";
      return json;
     }

   bool             BuildHistoryAndPnlJson(string &history_json,string &pnl_json)
     {
      history_json="[]";

      datetime now=TimeCurrent();
      datetime today_from=StartOfDay(now);
      datetime last_week_from=now-(7*86400);
      datetime last_month_from=now-(30*86400);
      datetime history_from=now-(m_config.trade_history_days*86400);
      datetime earliest_from=today_from;

      if(last_week_from<earliest_from)
         earliest_from=last_week_from;
      if(last_month_from<earliest_from)
         earliest_from=last_month_from;
      if(history_from<earliest_from)
         earliest_from=history_from;
      if(m_has_custom_range && m_custom_from<earliest_from)
         earliest_from=m_custom_from;

      RedisPnlRangeAccumulator today_range;
      RedisPnlRangeAccumulator last_week_range;
      RedisPnlRangeAccumulator last_month_range;
      RedisPnlRangeAccumulator custom_range;
      ResetPnlRange(today_range,today_from,now);
      ResetPnlRange(last_week_range,last_week_from,now);
      ResetPnlRange(last_month_range,last_month_from,now);
      ResetPnlRange(custom_range,0,0);
      if(m_has_custom_range)
         ResetPnlRange(custom_range,m_custom_from,m_custom_to);

      if(!HistorySelect(earliest_from,now))
        {
         LogMessage(StringFormat("Redis HTTP export failed to select account history. error=%d",GetLastError()));
         pnl_json="{"+
                  BuildPnlRangeJson("today",today_range)+","+
                  BuildPnlRangeJson("last_week",last_week_range)+","+
                  BuildPnlRangeJson("last_month",last_month_range)+
                  (m_has_custom_range ? ","+BuildPnlRangeJson("custom",custom_range) : "")+
                  "}";
         return false;
        }

      string deals_json="[";
      bool first_deal=true;
      int exported_deals=0;
      int total=HistoryDealsTotal();
      for(int i=total-1;i>=0;i--)
        {
         ulong ticket=HistoryDealGetTicket(i);
         if(ticket==0)
            continue;

         ENUM_DEAL_TYPE deal_type=(ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket,DEAL_TYPE);
         if(!IsTradeDealType(deal_type))
            continue;

         datetime deal_time=(datetime)HistoryDealGetInteger(ticket,DEAL_TIME);
         double volume=HistoryDealGetDouble(ticket,DEAL_VOLUME);
         double profit=HistoryDealGetDouble(ticket,DEAL_PROFIT);
         double commission=HistoryDealGetDouble(ticket,DEAL_COMMISSION);
         double swap=HistoryDealGetDouble(ticket,DEAL_SWAP);
         double fee=HistoryDealGetDouble(ticket,DEAL_FEE);
         double net=profit+commission+swap+fee;

         AccumulatePnlRange(today_range,deal_time,volume,profit,commission,swap,fee);
         AccumulatePnlRange(last_week_range,deal_time,volume,profit,commission,swap,fee);
         AccumulatePnlRange(last_month_range,deal_time,volume,profit,commission,swap,fee);
         if(m_has_custom_range)
            AccumulatePnlRange(custom_range,deal_time,volume,profit,commission,swap,fee);

         if(!m_config.include_trade_history || deal_time<history_from || exported_deals>=m_config.max_deals_per_push)
            continue;

         ENUM_DEAL_ENTRY deal_entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket,DEAL_ENTRY);
         if(!first_deal)
            deals_json+=",";
         first_deal=false;

         deals_json+="{"+
                     "\"ticket\":"+ULongToText(ticket)+","+
                     "\"order\":"+LongToText(HistoryDealGetInteger(ticket,DEAL_ORDER))+","+
                     "\"position_id\":"+LongToText(HistoryDealGetInteger(ticket,DEAL_POSITION_ID))+","+
                     "\"time\":"+LongToText((long)deal_time)+","+
                     "\"time_text\":"+JsonString(DateTimeToIsoText(deal_time))+","+
                     "\"symbol\":"+JsonString(HistoryDealGetString(ticket,DEAL_SYMBOL))+","+
                     "\"type\":"+JsonString(EnumToString(deal_type))+","+
                     "\"entry\":"+JsonString(EnumToString(deal_entry))+","+
                     "\"reason\":"+JsonString(EnumToString((ENUM_DEAL_REASON)HistoryDealGetInteger(ticket,DEAL_REASON)))+","+
                     "\"volume\":"+DoubleToString(volume,2)+","+
                     "\"price\":"+DoubleToString(HistoryDealGetDouble(ticket,DEAL_PRICE),8)+","+
                     "\"profit\":"+DoubleToString(profit,2)+","+
                     "\"commission\":"+DoubleToString(commission,2)+","+
                     "\"swap\":"+DoubleToString(swap,2)+","+
                     "\"fee\":"+DoubleToString(fee,2)+","+
                     "\"net\":"+DoubleToString(net,2)+","+
                     "\"magic\":"+LongToText(HistoryDealGetInteger(ticket,DEAL_MAGIC))+","+
                     "\"comment\":"+JsonString(HistoryDealGetString(ticket,DEAL_COMMENT))+
                     "}";
         exported_deals++;
        }
      deals_json+="]";
      history_json=deals_json;

      pnl_json="{"+
               BuildPnlRangeJson("today",today_range)+","+
               BuildPnlRangeJson("last_week",last_week_range)+","+
               BuildPnlRangeJson("last_month",last_month_range)+
               (m_has_custom_range ? ","+BuildPnlRangeJson("custom",custom_range) : "")+
               "}";
      return true;
     }

   string           BuildAccountStateJson()
     {
      return "{"+
             "\"login\":"+LongToText((long)AccountInfoInteger(ACCOUNT_LOGIN))+","+
             "\"name\":"+JsonString(AccountInfoString(ACCOUNT_NAME))+","+
             "\"server\":"+JsonString(AccountInfoString(ACCOUNT_SERVER))+","+
             "\"company\":"+JsonString(AccountInfoString(ACCOUNT_COMPANY))+","+
             "\"currency\":"+JsonString(AccountInfoString(ACCOUNT_CURRENCY))+","+
             "\"leverage\":"+LongToText((long)AccountInfoInteger(ACCOUNT_LEVERAGE))+","+
             "\"balance\":"+DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2)+","+
             "\"equity\":"+DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2)+","+
             "\"profit\":"+DoubleToString(AccountInfoDouble(ACCOUNT_PROFIT),2)+","+
             "\"margin\":"+DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN),2)+","+
             "\"free_margin\":"+DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE),2)+","+
             "\"margin_level\":"+DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_LEVEL),2)+","+
             "\"trade_allowed\":"+JsonBool((bool)AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))+","+
             "\"expert_allowed\":"+JsonBool((bool)AccountInfoInteger(ACCOUNT_TRADE_EXPERT))+
             "}";
     }

   string           BuildPayload()
     {
      string history_json="[]";
      string pnl_json="{}";
      BuildHistoryAndPnlJson(history_json,pnl_json);

      return "{"+
             "\"protocol_version\":"+JsonString("2")+","+
             "\"ea_name\":"+JsonString(m_config.ea_name)+","+
             "\"ea_version\":"+JsonString(m_config.ea_version)+","+
             "\"mode\":"+JsonString(m_config.mode_name)+","+
             "\"channel_id\":"+JsonString(m_config.channel_id)+","+
             "\"timestamp\":"+LongToText((long)TimeCurrent())+","+
             "\"timestamp_text\":"+JsonString(DateTimeToIsoText(TimeCurrent()))+","+
             "\"account\":"+BuildAccountStateJson()+","+
             "\"terminal\":"+
             "{"+
             "\"connected\":"+JsonBool((bool)TerminalInfoInteger(TERMINAL_CONNECTED))+","+
             "\"trade_allowed\":"+JsonBool((bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))+","+
             "\"mql_trade_allowed\":"+JsonBool((bool)MQLInfoInteger(MQL_TRADE_ALLOWED))+
             "},"+
             "\"copy_settings\":"+
             "{"+
             "\"copy_positions\":"+JsonBool(m_config.copy_positions)+","+
             "\"copy_pending_orders\":"+JsonBool(m_config.copy_pending_orders)+","+
             "\"copy_stop_loss\":"+JsonBool(m_config.copy_stop_loss)+","+
             "\"copy_take_profit\":"+JsonBool(m_config.copy_take_profit)+","+
             "\"copy_expirations\":"+JsonBool(m_config.copy_expirations)+","+
             "\"volume_multiplier\":"+DoubleToString(m_config.volume_multiplier,2)+","+
             "\"enable_slave_time_schedule\":"+JsonBool(m_config.enable_slave_time_schedule)+","+
             "\"simple_lot_window\":"+JsonBool(m_config.simple_lot_window)+
             "},"+
             "\"pnl\":"+pnl_json+","+
             "\"open_positions\":"+BuildOpenPositionsJson()+","+
             "\"pending_orders\":"+BuildPendingOrdersJson()+","+
             "\"trade_history\":"+history_json+
             "}";
     }

   void             ReportStatus(const string message,const bool success)
     {
      if(success)
        {
         if(m_last_status!="" && m_last_status!=message)
            LogMessage(message);
         m_last_status="";
         return;
        }

      if(m_last_status!=message)
         LogMessage(message);
      m_last_status=message;
     }

public:
                     CRedisHttpExporter()
     {
      m_last_publish=0;
      m_force_publish=false;
      m_last_status="";
      m_endpoint_url="";
      m_has_custom_range=false;
      m_custom_from=0;
      m_custom_to=0;
     }

   bool             Initialize(const RedisHttpExportConfig &config)
     {
      m_config=config;
      m_last_publish=0;
      m_force_publish=false;
      m_last_status="";
      m_endpoint_url="";
      m_has_custom_range=false;
      m_custom_from=0;
      m_custom_to=0;

      if(!m_config.enabled)
         return true;

      string base_url=TrimString(m_config.base_url);
      if(base_url=="")
        {
         LogMessage("Redis HTTP export requires RedisHttpBaseUrl.");
         return false;
        }

      m_endpoint_url=JoinUrl(base_url,m_config.endpoint_path);
      if(m_endpoint_url=="")
        {
         LogMessage("Redis HTTP export could not build a valid endpoint URL.");
         return false;
        }

      if(!m_config.allow_insecure_http && !IsSecureHttpUrl(m_endpoint_url))
        {
         LogMessage("Redis HTTP export blocks non-HTTPS endpoints. Set RedisHttpAllowInsecureHttp=true only for trusted local development.");
         return false;
        }

      if(m_config.timeout_ms<100)
        {
         LogMessage(StringFormat("Invalid RedisHttpTimeoutMs value: %d",m_config.timeout_ms));
         return false;
        }

      if(m_config.publish_interval_sec<1)
        {
         LogMessage(StringFormat("Invalid RedisHttpPublishIntervalSec value: %d",m_config.publish_interval_sec));
         return false;
        }

      if(m_config.trade_history_days<1)
        {
         LogMessage(StringFormat("Invalid RedisHttpTradeHistoryDays value: %d",m_config.trade_history_days));
         return false;
        }

      if(m_config.max_deals_per_push<1)
        {
         LogMessage(StringFormat("Invalid RedisHttpMaxDealsPerPush value: %d",m_config.max_deals_per_push));
         return false;
        }

      string custom_from_text=TrimString(m_config.custom_from_date);
      string custom_to_text=TrimString(m_config.custom_to_date);
      if((custom_from_text=="")!=(custom_to_text==""))
        {
         LogMessage("Redis custom date export requires both RedisHttpCustomFromDate and RedisHttpCustomToDate.");
         return false;
        }

      if(custom_from_text!="" && custom_to_text!="")
        {
         if(!ParseDateInput(custom_from_text,false,m_custom_from))
           {
            LogMessage(StringFormat("Invalid RedisHttpCustomFromDate value: %s",m_config.custom_from_date));
            return false;
           }
         if(!ParseDateInput(custom_to_text,true,m_custom_to))
           {
            LogMessage(StringFormat("Invalid RedisHttpCustomToDate value: %s",m_config.custom_to_date));
            return false;
           }
         if(m_custom_from>m_custom_to)
           {
            LogMessage("Redis custom date range is invalid because the start date is after the end date.");
            return false;
           }
         m_has_custom_range=true;
        }

      LogMessage(StringFormat("Redis HTTP export enabled. endpoint=%s interval=%d sec history=%d days",
                              m_endpoint_url,
                              m_config.publish_interval_sec,
                              m_config.trade_history_days));
      m_force_publish=true;
      return true;
     }

   bool             IsConfigured()
     {
      return m_config.enabled && m_endpoint_url!="";
     }

   string           EndpointUrl()
     {
      return m_endpoint_url;
     }

   void             QueuePublish()
     {
      if(IsConfigured())
         m_force_publish=true;
     }

   bool             PublishNow()
     {
      if(!IsConfigured())
         return false;

      string payload=BuildPayload();
      char post[];
      char response[];
      string response_headers="";
      int bytes=StringToCharArray(payload,post,0,StringLen(payload),CP_UTF8);
      if(bytes<=0)
         return false;
      ArrayResize(post,bytes);

      string headers="Content-Type: application/json\r\nAccept: application/json\r\nUser-Agent: FXTradeCopperRedis/1.0\r\n";
      string auth_header_name=TrimString(m_config.auth_header_name);
      string auth_token=TrimString(m_config.auth_token);
      if(auth_header_name!="" && auth_token!="")
        {
         string auth_value=m_config.use_bearer_token ? ("Bearer "+auth_token) : auth_token;
         headers+=auth_header_name+": "+auth_value+"\r\n";
        }

      ResetLastError();
      int status=WebRequest("POST",m_endpoint_url,headers,m_config.timeout_ms,post,response,response_headers);
      if(status<200 || status>=300)
        {
         int error_code=GetLastError();
         string response_text=CharArrayToString(response,0,-1,CP_UTF8);
         if(status==-1)
           {
            string message=StringFormat("Redis HTTP export failed. error=%d url=%s. Add this base URL to MT5: %s",
                                        error_code,
                                        m_endpoint_url,
                                        m_config.base_url);
            ReportStatus(message,false);
           }
         else
           {
            string message=StringFormat("Redis HTTP export returned status %d for %s. response=%s",
                                        status,
                                        m_endpoint_url,
                                        response_text);
            ReportStatus(message,false);
           }
         return false;
        }

      m_last_publish=TimeCurrent();
      m_force_publish=false;
      ReportStatus("Redis HTTP export connection restored.",true);
      return true;
     }

   void             MaybePublish()
     {
      if(!IsConfigured())
         return;

      datetime now=TimeCurrent();
      if(!m_force_publish && m_last_publish>0 && (now-m_last_publish)<m_config.publish_interval_sec)
         return;

      PublishNow();
     }
  };
