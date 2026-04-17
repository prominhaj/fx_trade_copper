//+------------------------------------------------------------------+
//|                                              fx_trade_copper.mq5 |
//|                          Copyright 2024-2026, FX Trade Copper     |
//|                                         https://www.allanmaug.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024-2026, FX Trade Copper"
#property link      "https://www.allanmaug.com"
#property version   "3.10"
#property strict

#define PROTOCOL_VERSION "2"
#define COMMENT_PREFIX "TC"
#define EMPTY_BLOB "-"

enum ENUM_MODE
  {
   MODE_MASTER,
   MODE_SLAVE
  };

input ENUM_MODE Mode = MODE_SLAVE;
input string ChannelId = "default";
input string SymbolMappings = "XAUUSD=XAUUSD";
input int MagicNumber = 12345;
input double VolumeMultiplier = 1.0;
input int TimerIntervalMs = 50;
input bool PublishOnTradeEvents = true;
input bool CopyPositions = true;
input bool CopyPendingOrders = true;
input bool CopyStopLoss = true;
input bool CopyTakeProfit = true;
input bool CopyExpirations = true;
input bool SyncExistingMasterTradesOnSlaveStart = false;
input bool ClearCopiedTradesOnSlaveStart = true;
input bool EnableSlaveTimeSchedule = false;
input int ScheduleGmtOffsetHours = 6;
input bool UseSimpleWeekdayFilter = false;
input bool FollowSunday = false;
input bool FollowMonday = true;
input bool FollowTuesday = true;
input bool FollowWednesday = true;
input bool FollowThursday = true;
input bool FollowFriday = true;
input bool FollowSaturday = false;
input bool UseSimpleTimeRange = false;
input string SimpleCopyStartTime = "00:00";
input string SimpleCopyEndTime = "23:59";
input bool UseSimpleCopyStopWindow = false;
input bool StopCopySunday = false;
input bool StopCopyMonday = false;
input bool StopCopyTuesday = false;
input bool StopCopyWednesday = false;
input bool StopCopyThursday = false;
input bool StopCopyFriday = false;
input bool StopCopySaturday = false;
input string SimpleCopyStopStartTime = "04:00";
input string SimpleCopyStopEndTime = "10:00";
input bool UseSimpleLotMultiplierWindow = false;
input bool LotMultiplierSunday = true;
input bool LotMultiplierMonday = true;
input bool LotMultiplierTuesday = true;
input bool LotMultiplierWednesday = true;
input bool LotMultiplierThursday = true;
input bool LotMultiplierFriday = true;
input bool LotMultiplierSaturday = true;
input string SimpleLotMultiplierStartTime = "01:00";
input string SimpleLotMultiplierEndTime = "12:00";
input double SimpleLotTimeMultiplier = 2.0;
input string CopyScheduleRules = "";
input string LotMultiplierScheduleRules = "";
input bool AutoMapByBaseSymbol = true;
input bool VerboseLogs = true;

struct SymbolMapEntry
  {
   string master_symbol;
   string slave_symbol;
  };

struct RemotePosition
  {
   long master_ticket;
   string master_symbol;
   string slave_symbol;
   double volume;
   ENUM_POSITION_TYPE position_type;
   double sl;
   double tp;
  };

struct RemoteOrder
  {
   long master_ticket;
   string master_symbol;
   string slave_symbol;
   double volume;
   ENUM_ORDER_TYPE order_type;
   double price;
   double stop_limit;
   double sl;
   double tp;
   datetime expiration;
  };

struct CopyScheduleRule
  {
   int day_mask;
   int start_minute;
   int end_minute;
   bool allow_copy;
   string description;
  };

struct LotMultiplierScheduleRule
  {
   int day_mask;
   int start_minute;
   int end_minute;
   double multiplier;
   string description;
  };

class CTradeSimple
  {
private:
   ulong             m_magic;

   bool              PrepareSymbol(const string symbol)
     {
      return SymbolSelect(symbol,true);
     }

   ENUM_ORDER_TYPE_FILLING ResolveFillingMode(const string symbol)
     {
      long filling_modes=(long)SymbolInfoInteger(symbol,SYMBOL_FILLING_MODE);
      if((filling_modes & SYMBOL_FILLING_FOK)==SYMBOL_FILLING_FOK)
         return ORDER_FILLING_FOK;
      if((filling_modes & SYMBOL_FILLING_IOC)==SYMBOL_FILLING_IOC)
         return ORDER_FILLING_IOC;
      return ORDER_FILLING_RETURN;
     }

   bool              SupportsSpecifiedExpiration(const string symbol)
     {
      long expiration_modes=(long)SymbolInfoInteger(symbol,SYMBOL_EXPIRATION_MODE);
      return (expiration_modes & SYMBOL_EXPIRATION_SPECIFIED)==SYMBOL_EXPIRATION_SPECIFIED;
     }

   void              SanitizeStops(const string symbol,const ENUM_ORDER_TYPE type,const double reference_price,double &sl,double &tp)
     {
      double point=SymbolInfoDouble(symbol,SYMBOL_POINT);
      int stops_level=(int)SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL);
      if(point<=0.0 || stops_level<=0)
         return;

      double min_distance=point*stops_level;
      if(type==ORDER_TYPE_BUY || type==ORDER_TYPE_BUY_LIMIT || type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_BUY_STOP_LIMIT)
        {
         if(sl>0.0 && sl>=reference_price-min_distance)
            sl=0.0;
         if(tp>0.0 && tp<=reference_price+min_distance)
            tp=0.0;
        }
      else if(type==ORDER_TYPE_SELL || type==ORDER_TYPE_SELL_LIMIT || type==ORDER_TYPE_SELL_STOP || type==ORDER_TYPE_SELL_STOP_LIMIT)
        {
         if(sl>0.0 && sl<=reference_price+min_distance)
            sl=0.0;
         if(tp>0.0 && tp>=reference_price-min_distance)
            tp=0.0;
        }
     }

   void              LogRequestFailure(const MqlTradeRequest &request,const MqlTradeResult &result,const int error_code)
     {
      PrintFormat("[FXTradeCopper] OrderSend failed. err=%d retcode=%u(%s) type=%d action=%d symbol=%s volume=%.4f price=%.5f stoplimit=%.5f sl=%.5f tp=%.5f fill=%d time=%d expiration=%I64d comment=%s",
                  error_code,
                  result.retcode,
                  TradeRetcodeDescription(result.retcode),
                  (int)request.type,
                  (int)request.action,
                  request.symbol,
                  request.volume,
                  request.price,
                  request.stoplimit,
                  request.sl,
                  request.tp,
                  (int)request.type_filling,
                  (int)request.type_time,
                  (long)request.expiration,
                  request.comment);
     }

   bool              CanRetryFilling(const MqlTradeRequest &request)
     {
      return request.action==TRADE_ACTION_DEAL || request.action==TRADE_ACTION_PENDING;
     }

   bool              IsSuccessfulRetcode(const uint retcode)
     {
      return retcode==TRADE_RETCODE_DONE ||
             retcode==TRADE_RETCODE_DONE_PARTIAL ||
             retcode==TRADE_RETCODE_PLACED ||
             retcode==TRADE_RETCODE_NO_CHANGES;
     }

   bool              SendRequest(MqlTradeRequest &request,MqlTradeResult &result)
     {
      string trade_reason="";
      if(!SlaveTradeAllowed(trade_reason))
        {
         ZeroMemory(result);
         if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
            result.retcode=TRADE_RETCODE_CLIENT_DISABLES_AT;
         else if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
            result.retcode=TRADE_RETCODE_SERVER_DISABLES_AT;
         else if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
            result.retcode=TRADE_RETCODE_TRADE_DISABLED;
         else if(!TerminalInfoInteger(TERMINAL_CONNECTED))
            result.retcode=TRADE_RETCODE_CONNECTION;
         return false;
        }

      if(request.symbol!="" && !PrepareSymbol(request.symbol))
        {
         PrintFormat("[FXTradeCopper] SymbolSelect failed for %s. error=%d",request.symbol,GetLastError());
         return false;
        }

      if(request.action==TRADE_ACTION_DEAL || request.action==TRADE_ACTION_PENDING)
        {
         SanitizeStops(request.symbol,request.type,request.price,request.sl,request.tp);
        }

      if(request.action==TRADE_ACTION_PENDING && request.expiration>0 && !SupportsSpecifiedExpiration(request.symbol))
        {
         request.type_time=ORDER_TIME_GTC;
         request.expiration=0;
        }

      ENUM_ORDER_TYPE_FILLING candidates[3];
      int candidate_count=0;
      ENUM_ORDER_TYPE_FILLING preferred=request.type_filling;
      candidates[candidate_count++]=preferred;

      if(CanRetryFilling(request))
        {
         if(preferred!=ORDER_FILLING_IOC)
            candidates[candidate_count++]=ORDER_FILLING_IOC;
         if(candidate_count<3 && preferred!=ORDER_FILLING_FOK)
            candidates[candidate_count++]=ORDER_FILLING_FOK;
         if(candidate_count<3 && preferred!=ORDER_FILLING_RETURN)
            candidates[candidate_count++]=ORDER_FILLING_RETURN;
        }

      for(int i=0;i<candidate_count;i++)
        {
         MqlTradeRequest attempt=request;
         ZeroMemory(result);
         if(CanRetryFilling(attempt))
            attempt.type_filling=candidates[i];

         ResetLastError();
         if(!OrderSend(attempt,result))
           {
            int error_code=GetLastError();
            LogRequestFailure(attempt,result,error_code);
            if(result.retcode!=TRADE_RETCODE_INVALID_FILL)
               break;
            continue;
           }

         if(IsSuccessfulRetcode(result.retcode))
           {
            request=attempt;
            return true;
           }

         LogRequestFailure(attempt,result,GetLastError());
         if(result.retcode!=TRADE_RETCODE_INVALID_FILL)
            break;
        }

      return false;
     }

public:
   void              SetExpertMagicNumber(const ulong magic)
     {
      m_magic=magic;
     }

   bool              Buy(const double volume,const string symbol,const double sl,const double tp,const string comment)
     {
      return ExecuteMarket(ORDER_TYPE_BUY,volume,symbol,sl,tp,comment);
     }

   bool              Sell(const double volume,const string symbol,const double sl,const double tp,const string comment)
     {
      return ExecuteMarket(ORDER_TYPE_SELL,volume,symbol,sl,tp,comment);
     }

   bool              ExecuteMarket(const ENUM_ORDER_TYPE type,const double volume,const string symbol,const double sl,const double tp,const string comment)
     {
      MqlTick tick;
      if(!SymbolInfoTick(symbol,tick))
         return false;

      MqlTradeRequest request;
      MqlTradeResult result;
      ZeroMemory(request);
      ZeroMemory(result);

      request.action=TRADE_ACTION_DEAL;
      request.symbol=symbol;
      request.volume=volume;
      request.type=type;
      request.price=(type==ORDER_TYPE_BUY) ? tick.ask : tick.bid;
      request.sl=sl;
      request.tp=tp;
      request.deviation=100;
      request.magic=m_magic;
      request.comment=comment;
      request.type_time=ORDER_TIME_GTC;
      request.type_filling=ResolveFillingMode(symbol);
      return SendRequest(request,result);
     }

   bool              PositionModify(const ulong ticket,const double sl,const double tp)
     {
      if(!PositionSelectByTicket(ticket))
         return false;

      MqlTradeRequest request;
      MqlTradeResult result;
      ZeroMemory(request);
      ZeroMemory(result);

      request.action=TRADE_ACTION_SLTP;
      request.position=ticket;
      request.symbol=PositionGetString(POSITION_SYMBOL);
      request.sl=sl;
      request.tp=tp;
      request.magic=m_magic;
      return SendRequest(request,result);
     }

   bool              PositionClose(const ulong ticket)
     {
      if(!PositionSelectByTicket(ticket))
         return false;

      string symbol=PositionGetString(POSITION_SYMBOL);
      double volume=PositionGetDouble(POSITION_VOLUME);
      ENUM_POSITION_TYPE position_type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      MqlTick tick;
      if(!SymbolInfoTick(symbol,tick))
         return false;

      MqlTradeRequest request;
      MqlTradeResult result;
      ZeroMemory(request);
      ZeroMemory(result);

      request.action=TRADE_ACTION_DEAL;
      request.position=ticket;
      request.symbol=symbol;
      request.volume=volume;
      request.type=(position_type==POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      request.price=(request.type==ORDER_TYPE_BUY) ? tick.ask : tick.bid;
      request.deviation=100;
      request.magic=m_magic;
      request.type_time=ORDER_TIME_GTC;
      request.type_filling=ResolveFillingMode(symbol);
      return SendRequest(request,result);
     }

   bool              PendingCreate(const ENUM_ORDER_TYPE type,const double volume,const string symbol,const double price,const double stop_limit,const double sl,const double tp,const datetime expiration,const string comment)
     {
      MqlTradeRequest request;
      MqlTradeResult result;
      ZeroMemory(request);
      ZeroMemory(result);

      request.action=TRADE_ACTION_PENDING;
      request.symbol=symbol;
      request.volume=volume;
      request.type=type;
      request.price=price;
      request.stoplimit=stop_limit;
      request.sl=sl;
      request.tp=tp;
      request.magic=m_magic;
      request.comment=comment;
      request.type_filling=ResolveFillingMode(symbol);
      request.type_time=(expiration>0) ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC;
      request.expiration=expiration;
      return SendRequest(request,result);
     }

   bool              PendingModify(const ulong ticket,const string symbol,const double price,const double stop_limit,const double sl,const double tp,const datetime expiration)
     {
      MqlTradeRequest request;
      MqlTradeResult result;
      ZeroMemory(request);
      ZeroMemory(result);

      request.action=TRADE_ACTION_MODIFY;
      request.order=ticket;
      request.symbol=symbol;
      request.price=price;
      request.stoplimit=stop_limit;
      request.sl=sl;
      request.tp=tp;
      request.magic=m_magic;
      request.type_time=(expiration>0) ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC;
      request.expiration=expiration;
      return SendRequest(request,result);
     }

   bool              PendingDelete(const ulong ticket)
     {
      MqlTradeRequest request;
      MqlTradeResult result;
      ZeroMemory(request);
      ZeroMemory(result);

      request.action=TRADE_ACTION_REMOVE;
      request.order=ticket;
      request.magic=m_magic;
      return SendRequest(request,result);
     }
  };

CTradeSimple trade;
SymbolMapEntry g_symbol_maps[];
string g_channel_key="";
string g_transport_file_name="";
string g_last_master_state="";
string g_last_slave_snapshot="";
ulong g_publish_sequence=0;
ulong g_last_applied_sequence=0;
long g_last_source_account=0;
string g_last_trade_block_reason="";
bool g_slave_start_baseline_ready=false;
long g_ignored_master_position_tickets[];
long g_ignored_master_order_tickets[];
CopyScheduleRule g_copy_schedule_rules[];
LotMultiplierScheduleRule g_lot_multiplier_schedule_rules[];
bool g_has_copy_allow_rules=false;
string g_last_copy_schedule_reason="";
string g_last_lot_schedule_description="";

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

string ToUpperAscii(const string value)
  {
   string result="";
   int length=StringLen(value);
   for(int i=0;i<length;i++)
     {
      int ch=StringGetCharacter(value,i);
      if(ch>='a' && ch<='z')
         ch-=32;
      result+=CharToString((ushort)ch);
     }
   return result;
  }

string ReplaceString(const string value,const string search,const string replacement)
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

int DayMaskForDayOfWeek(const int day_of_week)
  {
   if(day_of_week<0 || day_of_week>6)
      return 0;
   return 1<<day_of_week;
  }

bool ParseDayToken(const string token,int &day_mask)
  {
   string normalized=ToUpperAscii(TrimString(token));
   if(normalized=="")
      return false;
   if(normalized=="ALL" || normalized=="ANY" || normalized=="EVERYDAY" || normalized=="DAILY")
     {
      day_mask=127;
      return true;
     }
   if(normalized=="SUN" || normalized=="SUNDAY")
      day_mask=DayMaskForDayOfWeek(0);
   else if(normalized=="MON" || normalized=="MONDAY")
      day_mask=DayMaskForDayOfWeek(1);
   else if(normalized=="TUE" || normalized=="TUESDAY")
      day_mask=DayMaskForDayOfWeek(2);
   else if(normalized=="WED" || normalized=="WEDNESDAY")
      day_mask=DayMaskForDayOfWeek(3);
   else if(normalized=="THU" || normalized=="THURSDAY")
      day_mask=DayMaskForDayOfWeek(4);
   else if(normalized=="FRI" || normalized=="FRIDAY")
      day_mask=DayMaskForDayOfWeek(5);
   else if(normalized=="SAT" || normalized=="SATURDAY")
      day_mask=DayMaskForDayOfWeek(6);
   else
      return false;
   return true;
  }

bool ParseDayMask(const string text,int &day_mask)
  {
   day_mask=0;
   string normalized=ReplaceString(ToUpperAscii(TrimString(text))," ","");
   if(normalized=="")
      return false;

   string parts[];
   int count=StringSplit(normalized,',',parts);
   if(count<=0)
      count=1;

   if(count==1 && ArraySize(parts)==0)
     {
      int single_day_mask=0;
      if(!ParseDayToken(normalized,single_day_mask))
         return false;
      day_mask=single_day_mask;
      return true;
     }

   for(int i=0;i<count;i++)
     {
      int single_day_mask=0;
      if(!ParseDayToken(parts[i],single_day_mask))
         return false;
      day_mask|=single_day_mask;
     }
   return day_mask!=0;
  }

bool ParseTimeOfDay(const string text,int &minutes_of_day)
  {
   minutes_of_day=0;
   string value=TrimString(text);
   string parts[];
   if(StringSplit(value,':',parts)!=2)
      return false;

   int hour=(int)StringToInteger(parts[0]);
   int minute=(int)StringToInteger(parts[1]);
   if(hour<0 || hour>23 || minute<0 || minute>59)
      return false;

   minutes_of_day=hour*60+minute;
   return true;
  }

bool ParseWindowDefinition(const string text,int &day_mask,int &start_minute,int &end_minute)
  {
   day_mask=127;
   start_minute=0;
   end_minute=1439;

   string normalized=TrimString(text);
   if(normalized=="")
      return false;

   int space_index=StringFind(normalized," ",0);
   string day_part="";
   string time_part="";
   if(space_index>=0)
     {
      day_part=TrimString(StringSubstr(normalized,0,space_index));
      time_part=TrimString(StringSubstr(normalized,space_index+1));
     }
   else if(StringFind(normalized,":",0)>=0 || StringFind(normalized,"-",0)>=0)
      time_part=normalized;
   else
      day_part=normalized;

   if(day_part!="" && !ParseDayMask(day_part,day_mask))
      return false;

   if(time_part=="")
      return true;

   string range_parts[];
   if(StringSplit(time_part,'-',range_parts)!=2)
      return false;
   if(!ParseTimeOfDay(range_parts[0],start_minute))
      return false;
   if(!ParseTimeOfDay(range_parts[1],end_minute))
      return false;
   return true;
  }

bool WindowMatchesNow(const int day_mask,const int start_minute,const int end_minute,const int day_of_week,const int minute_of_day)
  {
   if(start_minute<=end_minute)
      return (day_mask & DayMaskForDayOfWeek(day_of_week))!=0 && minute_of_day>=start_minute && minute_of_day<=end_minute;

   int previous_day=(day_of_week+6)%7;
   bool current_day_match=((day_mask & DayMaskForDayOfWeek(day_of_week))!=0 && minute_of_day>=start_minute);
   bool previous_day_match=((day_mask & DayMaskForDayOfWeek(previous_day))!=0 && minute_of_day<=end_minute);
   return current_day_match || previous_day_match;
  }

void GetScheduleClock(int &day_of_week,int &minute_of_day,string &clock_text)
  {
   datetime schedule_time=TimeGMT()+(ScheduleGmtOffsetHours*3600);
   MqlDateTime time_parts;
   TimeToStruct(schedule_time,time_parts);
   day_of_week=time_parts.day_of_week;
   minute_of_day=time_parts.hour*60+time_parts.min;
   clock_text=StringFormat("%04d-%02d-%02d %02d:%02d GMT%+d",
                           time_parts.year,
                           time_parts.mon,
                           time_parts.day,
                           time_parts.hour,
                           time_parts.min,
                           ScheduleGmtOffsetHours);
  }

bool IsWeekdayFollowEnabled(const int day_of_week)
  {
   switch(day_of_week)
     {
      case 0:
         return FollowSunday;
      case 1:
         return FollowMonday;
      case 2:
         return FollowTuesday;
      case 3:
         return FollowWednesday;
      case 4:
         return FollowThursday;
      case 5:
         return FollowFriday;
      case 6:
         return FollowSaturday;
     }
   return false;
  }

bool IsCopyStopDayEnabled(const int day_of_week)
  {
   switch(day_of_week)
     {
      case 0:
         return StopCopySunday;
      case 1:
         return StopCopyMonday;
      case 2:
         return StopCopyTuesday;
      case 3:
         return StopCopyWednesday;
      case 4:
         return StopCopyThursday;
      case 5:
         return StopCopyFriday;
      case 6:
         return StopCopySaturday;
     }
   return false;
  }

bool IsLotMultiplierDayEnabled(const int day_of_week)
  {
   switch(day_of_week)
     {
      case 0:
         return LotMultiplierSunday;
      case 1:
         return LotMultiplierMonday;
      case 2:
         return LotMultiplierTuesday;
      case 3:
         return LotMultiplierWednesday;
      case 4:
         return LotMultiplierThursday;
      case 5:
         return LotMultiplierFriday;
      case 6:
         return LotMultiplierSaturday;
     }
   return false;
  }

bool HasActiveLotMultiplierSchedule()
  {
   return UseSimpleLotMultiplierWindow || ArraySize(g_lot_multiplier_schedule_rules)>0;
  }

bool MinuteInDailyRange(const int minute_of_day,const int start_minute,const int end_minute)
  {
   if(start_minute<=end_minute)
      return minute_of_day>=start_minute && minute_of_day<=end_minute;
   return minute_of_day>=start_minute || minute_of_day<=end_minute;
  }

string NormalizeSymbolKey(const string symbol)
  {
   string normalized=ToUpperAscii(TrimString(symbol));
   int last_dot=-1;
   for(int i=0;i<StringLen(normalized);i++)
     {
      if(StringGetCharacter(normalized,i)=='.')
         last_dot=i;
     }
   if(last_dot>0)
      normalized=StringSubstr(normalized,0,last_dot);
   return normalized;
  }

bool SymbolsEquivalent(const string left,const string right)
  {
   return NormalizeSymbolKey(left)==NormalizeSymbolKey(right);
  }

uint HashString32(const string value)
  {
   uint hash=2166136261;
   int length=StringLen(value);
   for(int i=0;i<length;i++)
     {
      hash^=(uint)StringGetCharacter(value,i);
      hash*=16777619;
     }
   return hash;
  }

string ChannelTag()
  {
   return StringFormat("%08X",HashString32(g_channel_key));
  }

void LogMessage(const string message)
  {
   if(VerboseLogs)
      Print("[FXTradeCopper] ",message);
  }

bool ReportCopyScheduleState(const string reason)
  {
   if(reason=="")
     {
      if(g_last_copy_schedule_reason!="")
         LogMessage("Slave copy schedule is active again.");
      g_last_copy_schedule_reason="";
      return true;
     }

   if(g_last_copy_schedule_reason!=reason)
      LogMessage(reason);
   g_last_copy_schedule_reason=reason;
   return false;
  }

void ReportLotScheduleState(const string description,const double multiplier)
  {
   string message=(description=="") ? StringFormat("Time-based lot multiplier reset to %.2f.",multiplier)
                                    : StringFormat("Time-based lot multiplier %.2f applied by rule %s.",multiplier,description);
   if(g_last_lot_schedule_description!=message)
      LogMessage(message);
   g_last_lot_schedule_description=message;
  }

string TradeRetcodeDescription(const uint retcode)
  {
   switch(retcode)
     {
      case TRADE_RETCODE_DONE:
         return "done";
      case TRADE_RETCODE_DONE_PARTIAL:
         return "done partial";
      case TRADE_RETCODE_PLACED:
         return "placed";
      case TRADE_RETCODE_NO_CHANGES:
         return "no changes";
      case TRADE_RETCODE_INVALID_VOLUME:
         return "invalid volume";
      case TRADE_RETCODE_INVALID_PRICE:
         return "invalid price";
      case TRADE_RETCODE_INVALID_STOPS:
         return "invalid stops";
      case TRADE_RETCODE_TRADE_DISABLED:
         return "trade disabled";
      case TRADE_RETCODE_MARKET_CLOSED:
         return "market closed";
      case TRADE_RETCODE_NO_MONEY:
         return "not enough money";
      case TRADE_RETCODE_PRICE_CHANGED:
         return "price changed";
      case TRADE_RETCODE_PRICE_OFF:
         return "no quotes";
      case TRADE_RETCODE_INVALID_EXPIRATION:
         return "invalid expiration";
      case TRADE_RETCODE_TOO_MANY_REQUESTS:
         return "too many requests";
      case TRADE_RETCODE_SERVER_DISABLES_AT:
         return "autotrading disabled by server";
      case TRADE_RETCODE_CLIENT_DISABLES_AT:
         return "autotrading disabled by client terminal";
      case TRADE_RETCODE_INVALID_FILL:
         return "invalid filling mode";
      case TRADE_RETCODE_CONNECTION:
         return "no trading connection";
      case TRADE_RETCODE_ONLY_REAL:
         return "real accounts only";
      case TRADE_RETCODE_LIMIT_ORDERS:
         return "pending order limit reached";
      case TRADE_RETCODE_LIMIT_VOLUME:
         return "volume limit reached";
     }
   return "unknown";
  }

bool ReportTradePermissionState(const string reason)
  {
   if(reason=="")
     {
      if(g_last_trade_block_reason!="")
         LogMessage("Slave trading permissions restored.");
      g_last_trade_block_reason="";
      return true;
     }

   if(g_last_trade_block_reason!=reason)
      LogMessage(reason);
   g_last_trade_block_reason=reason;
   return false;
  }

bool SlaveTradeAllowed(string &reason)
  {
   reason="";
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
      reason="Slave trading blocked: terminal is not connected to the trade server.";
   else if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      reason="Slave trading blocked: the slave terminal AutoTrading button is OFF. Enable AutoTrading on the MT5 toolbar.";
   else if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      reason="Slave trading blocked: this EA was attached without 'Allow Algo Trading'. Enable it in the EA properties on the slave chart.";
   else if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
      reason="Slave trading blocked: this account cannot trade. Check the login is not using an investor password and the broker has not set the account to read-only.";
   else if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
      reason="Slave trading blocked: the broker/server has disabled EA trading for this account.";

   return ReportTradePermissionState(reason);
  }

bool ParseCopyScheduleRules()
  {
   ArrayResize(g_copy_schedule_rules,0);
   g_has_copy_allow_rules=false;

   string rule_text=TrimString(CopyScheduleRules);
   if(rule_text=="")
      return true;

   string items[];
   int item_count=StringSplit(rule_text,';',items);
   for(int i=0;i<item_count;i++)
     {
      string item=TrimString(items[i]);
      if(item=="")
         continue;

      string parts[];
      if(StringSplit(item,'=',parts)!=2)
        {
         LogMessage(StringFormat("Invalid CopyScheduleRules entry: %s",item));
         return false;
        }

      int day_mask=0;
      int start_minute=0;
      int end_minute=0;
      if(!ParseWindowDefinition(parts[0],day_mask,start_minute,end_minute))
        {
         LogMessage(StringFormat("Invalid copy schedule window: %s",parts[0]));
         return false;
        }

      string action=ToUpperAscii(TrimString(parts[1]));
      bool allow_copy=false;
      if(action=="COPY" || action=="ALLOW" || action=="ON")
        {
         allow_copy=true;
         g_has_copy_allow_rules=true;
        }
      else if(action=="SKIP" || action=="BLOCK" || action=="OFF")
         allow_copy=false;
      else
        {
         LogMessage(StringFormat("Invalid copy schedule action: %s",parts[1]));
         return false;
        }

      int size=ArraySize(g_copy_schedule_rules);
      ArrayResize(g_copy_schedule_rules,size+1);
      g_copy_schedule_rules[size].day_mask=day_mask;
      g_copy_schedule_rules[size].start_minute=start_minute;
      g_copy_schedule_rules[size].end_minute=end_minute;
      g_copy_schedule_rules[size].allow_copy=allow_copy;
      g_copy_schedule_rules[size].description=TrimString(item);
     }
   return true;
  }

bool ParseLotMultiplierScheduleRules()
  {
   ArrayResize(g_lot_multiplier_schedule_rules,0);

   string rule_text=TrimString(LotMultiplierScheduleRules);
   if(rule_text=="")
      return true;

   string items[];
   int item_count=StringSplit(rule_text,';',items);
   for(int i=0;i<item_count;i++)
     {
      string item=TrimString(items[i]);
      if(item=="")
         continue;

      string parts[];
      if(StringSplit(item,'=',parts)!=2)
        {
         LogMessage(StringFormat("Invalid LotMultiplierScheduleRules entry: %s",item));
         return false;
        }

      int day_mask=0;
      int start_minute=0;
      int end_minute=0;
      if(!ParseWindowDefinition(parts[0],day_mask,start_minute,end_minute))
        {
         LogMessage(StringFormat("Invalid lot schedule window: %s",parts[0]));
         return false;
        }

      double multiplier=StringToDouble(TrimString(parts[1]));
      if(multiplier<0.0)
        {
         LogMessage(StringFormat("Invalid lot multiplier value: %s",parts[1]));
         return false;
        }

      int size=ArraySize(g_lot_multiplier_schedule_rules);
      ArrayResize(g_lot_multiplier_schedule_rules,size+1);
      g_lot_multiplier_schedule_rules[size].day_mask=day_mask;
      g_lot_multiplier_schedule_rules[size].start_minute=start_minute;
      g_lot_multiplier_schedule_rules[size].end_minute=end_minute;
      g_lot_multiplier_schedule_rules[size].multiplier=multiplier;
      g_lot_multiplier_schedule_rules[size].description=TrimString(item);
     }
   return true;
  }

bool ParseScheduleRules()
  {
   if(UseSimpleTimeRange)
     {
      int start_minute=0;
      int end_minute=0;
      if(!ParseTimeOfDay(SimpleCopyStartTime,start_minute))
        {
         LogMessage(StringFormat("Invalid SimpleCopyStartTime value: %s",SimpleCopyStartTime));
         return false;
        }
      if(!ParseTimeOfDay(SimpleCopyEndTime,end_minute))
        {
         LogMessage(StringFormat("Invalid SimpleCopyEndTime value: %s",SimpleCopyEndTime));
         return false;
        }
     }
   if(UseSimpleCopyStopWindow)
     {
      int start_minute=0;
      int end_minute=0;
      if(!ParseTimeOfDay(SimpleCopyStopStartTime,start_minute))
        {
         LogMessage(StringFormat("Invalid SimpleCopyStopStartTime value: %s",SimpleCopyStopStartTime));
         return false;
        }
      if(!ParseTimeOfDay(SimpleCopyStopEndTime,end_minute))
        {
         LogMessage(StringFormat("Invalid SimpleCopyStopEndTime value: %s",SimpleCopyStopEndTime));
         return false;
        }
     }
   if(UseSimpleLotMultiplierWindow)
     {
      int start_minute=0;
      int end_minute=0;
      if(!ParseTimeOfDay(SimpleLotMultiplierStartTime,start_minute))
        {
         LogMessage(StringFormat("Invalid SimpleLotMultiplierStartTime value: %s",SimpleLotMultiplierStartTime));
         return false;
        }
      if(!ParseTimeOfDay(SimpleLotMultiplierEndTime,end_minute))
        {
         LogMessage(StringFormat("Invalid SimpleLotMultiplierEndTime value: %s",SimpleLotMultiplierEndTime));
         return false;
        }
      if(SimpleLotTimeMultiplier<0.0)
        {
         LogMessage(StringFormat("Invalid SimpleLotTimeMultiplier value: %.2f",SimpleLotTimeMultiplier));
         return false;
        }
     }
   if(!ParseCopyScheduleRules())
      return false;
   if(!ParseLotMultiplierScheduleRules())
      return false;
   return true;
  }

bool SlaveCopyAllowedBySchedule(string &reason)
  {
   reason="";
   if(Mode!=MODE_SLAVE || !EnableSlaveTimeSchedule)
      return ReportCopyScheduleState(reason);

   int day_of_week=0;
   int minute_of_day=0;
   string clock_text="";
   GetScheduleClock(day_of_week,minute_of_day,clock_text);

   if(UseSimpleCopyStopWindow && IsCopyStopDayEnabled(day_of_week))
     {
      int start_minute=0;
      int end_minute=0;
      if(ParseTimeOfDay(SimpleCopyStopStartTime,start_minute) && ParseTimeOfDay(SimpleCopyStopEndTime,end_minute))
        {
         if(MinuteInDailyRange(minute_of_day,start_minute,end_minute))
           {
            reason=StringFormat("Slave copy stopped by simple stop window on this weekday: %s-%s at %s.",
                                SimpleCopyStopStartTime,
                                SimpleCopyStopEndTime,
                                clock_text);
            return ReportCopyScheduleState(reason);
           }
        }
     }

   if(UseSimpleWeekdayFilter && !IsWeekdayFollowEnabled(day_of_week))
     {
      reason=StringFormat("Slave copy skipped by weekday filter at %s.",clock_text);
      return ReportCopyScheduleState(reason);
     }

   if(UseSimpleTimeRange)
     {
      int start_minute=0;
      int end_minute=0;
      if(ParseTimeOfDay(SimpleCopyStartTime,start_minute) && ParseTimeOfDay(SimpleCopyEndTime,end_minute))
        {
         if(!MinuteInDailyRange(minute_of_day,start_minute,end_minute))
           {
            reason=StringFormat("Slave copy skipped by simple time range %s-%s at %s.",SimpleCopyStartTime,SimpleCopyEndTime,clock_text);
            return ReportCopyScheduleState(reason);
           }
        }
     }

   for(int i=0;i<ArraySize(g_copy_schedule_rules);i++)
     {
      if(!WindowMatchesNow(g_copy_schedule_rules[i].day_mask,g_copy_schedule_rules[i].start_minute,g_copy_schedule_rules[i].end_minute,day_of_week,minute_of_day))
         continue;

      if(g_copy_schedule_rules[i].allow_copy)
         return ReportCopyScheduleState("");

      reason=StringFormat("Slave copy skipped by GMT schedule rule %s at %s.",g_copy_schedule_rules[i].description,clock_text);
      return ReportCopyScheduleState(reason);
     }

   if(g_has_copy_allow_rules)
     {
      reason=StringFormat("Slave copy skipped because no COPY schedule rule is active at %s.",clock_text);
      return ReportCopyScheduleState(reason);
     }

   return ReportCopyScheduleState("");
  }

double ResolveTimeBasedLotMultiplier()
  {
   if(Mode!=MODE_SLAVE || (!EnableSlaveTimeSchedule && !HasActiveLotMultiplierSchedule()))
     {
      if(g_last_lot_schedule_description!="")
        {
         LogMessage("Time-based lot multiplier reset to 1.00.");
         g_last_lot_schedule_description="";
        }
      return 1.0;
     }

   int day_of_week=0;
   int minute_of_day=0;
   string clock_text="";
   GetScheduleClock(day_of_week,minute_of_day,clock_text);

   if(UseSimpleLotMultiplierWindow && IsLotMultiplierDayEnabled(day_of_week))
     {
      int start_minute=0;
      int end_minute=0;
      if(ParseTimeOfDay(SimpleLotMultiplierStartTime,start_minute) && ParseTimeOfDay(SimpleLotMultiplierEndTime,end_minute))
        {
         if(MinuteInDailyRange(minute_of_day,start_minute,end_minute))
           {
            ReportLotScheduleState(StringFormat("simple lot window %s-%s",SimpleLotMultiplierStartTime,SimpleLotMultiplierEndTime),
                                   SimpleLotTimeMultiplier);
            return SimpleLotTimeMultiplier;
           }
        }
     }

   for(int i=0;i<ArraySize(g_lot_multiplier_schedule_rules);i++)
     {
      if(!WindowMatchesNow(g_lot_multiplier_schedule_rules[i].day_mask,g_lot_multiplier_schedule_rules[i].start_minute,g_lot_multiplier_schedule_rules[i].end_minute,day_of_week,minute_of_day))
         continue;
      ReportLotScheduleState(g_lot_multiplier_schedule_rules[i].description,g_lot_multiplier_schedule_rules[i].multiplier);
      return g_lot_multiplier_schedule_rules[i].multiplier;
     }

   if(g_last_lot_schedule_description!="")
     {
      LogMessage(StringFormat("Time-based lot multiplier reset to 1.00 at %s.",clock_text));
      g_last_lot_schedule_description="";
     }
   return 1.0;
  }

string BuildTransportFileName()
  {
   return StringFormat("FXTradeCopper_%s.sync",SanitizeIdentifier(g_channel_key));
  }

bool ParseSymbolMappings()
  {
   ArrayResize(g_symbol_maps,0);
   string mapping_text=TrimString(SymbolMappings);
   if(mapping_text=="")
      mapping_text="XAUUSD=XAUUSD";
   string map_items[];
   int mapping_count=StringSplit(mapping_text,';',map_items);
   if(mapping_count<=0)
      return false;

   for(int i=0;i<mapping_count;i++)
     {
      string item=TrimString(map_items[i]);
      if(item=="")
         continue;

      string pair[];
      if(StringSplit(item,'=',pair)!=2)
         continue;

      string master_symbol=TrimString(pair[0]);
      string slave_symbol=TrimString(pair[1]);
      if(master_symbol=="" || slave_symbol=="")
         continue;

      int size=ArraySize(g_symbol_maps);
      ArrayResize(g_symbol_maps,size+1);
      g_symbol_maps[size].master_symbol=master_symbol;
      g_symbol_maps[size].slave_symbol=slave_symbol;
     }

   return ArraySize(g_symbol_maps)>0;
  }

string GetMappedSlaveSymbolTemplate(const string master_symbol)
  {
   for(int i=0;i<ArraySize(g_symbol_maps);i++)
     {
      if(g_symbol_maps[i].master_symbol==master_symbol)
         return g_symbol_maps[i].slave_symbol;
     }
   if(AutoMapByBaseSymbol)
     {
      for(int i=0;i<ArraySize(g_symbol_maps);i++)
        {
         if(SymbolsEquivalent(g_symbol_maps[i].master_symbol,master_symbol))
            return g_symbol_maps[i].slave_symbol;
        }
      return NormalizeSymbolKey(master_symbol);
     }
   return "";
  }

string ResolveBrokerSymbol(const string symbol_template)
  {
   if(symbol_template=="")
      return "";

   if(SymbolSelect(symbol_template,true))
      return symbol_template;

   if(!AutoMapByBaseSymbol)
      return "";

   string target_key=NormalizeSymbolKey(symbol_template);
   int total=SymbolsTotal(false);
   for(int i=0;i<total;i++)
     {
      string candidate=SymbolName(i,false);
      if(SymbolsEquivalent(candidate,target_key))
        {
         if(SymbolSelect(candidate,true))
            return candidate;
         return candidate;
        }
     }
   return "";
  }

string FindSlaveSymbol(const string master_symbol)
  {
   string template_symbol=GetMappedSlaveSymbolTemplate(master_symbol);
   string resolved=ResolveBrokerSymbol(template_symbol);
   if(resolved!="")
      return resolved;

   if(AutoMapByBaseSymbol)
     {
      resolved=ResolveBrokerSymbol(NormalizeSymbolKey(template_symbol));
      if(resolved!="")
         return resolved;

      resolved=ResolveBrokerSymbol(NormalizeSymbolKey(master_symbol));
      if(resolved!="")
         return resolved;
     }

   return "";
  }

bool IsMappedMasterSymbol(const string symbol)
  {
   return GetMappedSlaveSymbolTemplate(symbol)!="";
  }

bool IsMappedSlaveSymbol(const string symbol)
  {
   for(int i=0;i<ArraySize(g_symbol_maps);i++)
     {
      if(g_symbol_maps[i].slave_symbol==symbol)
         return true;
      if(AutoMapByBaseSymbol && SymbolsEquivalent(g_symbol_maps[i].slave_symbol,symbol))
         return true;
      }
   return false;
  }

string LongToText(const long value)
  {
   return StringFormat("%I64d",value);
  }

string ULongToText(const ulong value)
  {
   return StringFormat("%I64u",value);
  }

int VolumeDigits(const double step)
  {
   if(step<=0.0)
      return 2;

   int digits=0;
   double scaled=step;
   while(digits<8 && MathAbs(MathRound(scaled)-scaled)>0.0000001)
     {
      scaled*=10.0;
      digits++;
     }
   return digits;
  }

double NormalizeVolumeForSymbol(const string symbol,double volume)
  {
   double time_multiplier=ResolveTimeBasedLotMultiplier();
   double adjusted=volume*VolumeMultiplier*time_multiplier;
   double minimum=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
   double maximum=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);

   if(step<=0.0)
      step=0.01;
   if(minimum<=0.0)
      minimum=step;
   if(maximum<=0.0)
      maximum=adjusted;

   adjusted=MathMax(adjusted,minimum);
   adjusted=MathMin(adjusted,maximum);
   adjusted=MathFloor(adjusted/step+0.0000001)*step;
   adjusted=MathMax(adjusted,minimum);
   double normalized=NormalizeDouble(adjusted,VolumeDigits(step));
   if(VerboseLogs && (VolumeMultiplier!=1.0 || time_multiplier!=1.0) && VolumesDifferent(symbol,normalized,volume))
      LogMessage(StringFormat("Volume adjusted on %s: master %.2f -> slave %.2f (volume multiplier %.2f, time multiplier %.2f).",
                              symbol,
                              volume,
                              normalized,
                              VolumeMultiplier,
                              time_multiplier));
   return normalized;
  }

double NormalizePriceForSymbol(const string symbol,const double price)
  {
   if(price<=0.0)
      return 0.0;
   int digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
   return NormalizeDouble(price,digits);
  }

bool PricesDifferent(const string symbol,const double first,const double second)
  {
   double point=SymbolInfoDouble(symbol,SYMBOL_POINT);
   if(point<=0.0)
      point=0.00001;
   return MathAbs(first-second)>(point*0.5);
  }

bool VolumesDifferent(const string symbol,const double first,const double second)
  {
   double step=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
   if(step<=0.0)
      step=0.01;
   return MathAbs(first-second)>(step*0.5);
  }

bool OrderTypeIsPending(const ENUM_ORDER_TYPE order_type)
  {
   return order_type==ORDER_TYPE_BUY_LIMIT ||
          order_type==ORDER_TYPE_SELL_LIMIT ||
          order_type==ORDER_TYPE_BUY_STOP ||
          order_type==ORDER_TYPE_SELL_STOP ||
          order_type==ORDER_TYPE_BUY_STOP_LIMIT ||
          order_type==ORDER_TYPE_SELL_STOP_LIMIT;
  }

string BuildEntityComment(const string entity_type,const long master_ticket)
  {
   return StringFormat("%s|%s|%s|%s",COMMENT_PREFIX,ChannelTag(),entity_type,LongToText(master_ticket));
  }

bool IsCopiedCommentForChannel(const string comment)
  {
   string prefix=StringFormat("%s|%s|",COMMENT_PREFIX,ChannelTag());
   return StringFind(comment,prefix,0)==0;
  }

string ExtractEntityTypeFromComment(const string comment)
  {
   if(!IsCopiedCommentForChannel(comment))
      return "";
   string parts[];
   if(StringSplit(comment,'|',parts)<4)
      return "";
   return parts[2];
  }

long ExtractMasterTicketFromComment(const string comment)
  {
   if(!IsCopiedCommentForChannel(comment))
      return -1;
   string parts[];
   if(StringSplit(comment,'|',parts)<4)
      return -1;
   return StringToInteger(parts[3]);
  }

bool ContainsMasterTicket(const long &tickets[],const long ticket)
  {
   for(int i=0;i<ArraySize(tickets);i++)
     {
      if(tickets[i]==ticket)
         return true;
     }
   return false;
  }

void AddMasterTicket(long &tickets[],const long ticket)
  {
   if(ContainsMasterTicket(tickets,ticket))
      return;
   int size=ArraySize(tickets);
   ArrayResize(tickets,size+1);
   tickets[size]=ticket;
  }

void ExtractMasterTicketsFromBlob(const string blob,long &tickets[])
  {
   ArrayResize(tickets,0);
   string decoded=DecodeBlob(blob);
   if(decoded=="")
      return;

   string items[];
   int item_count=StringSplit(decoded,';',items);
   for(int i=0;i<item_count;i++)
     {
      string columns[];
      if(StringSplit(items[i],'^',columns)<1)
         continue;
      AddMasterTicket(tickets,StringToInteger(columns[0]));
     }
  }

string EncodeBlob(const string blob)
  {
   return (blob=="") ? EMPTY_BLOB : blob;
  }

string DecodeBlob(const string blob)
  {
   return (blob==EMPTY_BLOB) ? "" : blob;
  }

ulong FindSlavePositionTicket(const string symbol,const string comment)
  {
   for(int i=0;i<PositionsTotal();i++)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetInteger(POSITION_MAGIC)!=MagicNumber)
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=symbol)
         continue;
      if(PositionGetString(POSITION_COMMENT)!=comment)
         continue;
      return ticket;
     }
   return 0;
  }

ulong FindSlaveOrderTicket(const string symbol,const string comment)
  {
   for(int i=0;i<OrdersTotal();i++)
     {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0 || !OrderSelect(ticket))
         continue;
      if(OrderGetInteger(ORDER_MAGIC)!=MagicNumber)
         continue;
      if(OrderGetString(ORDER_SYMBOL)!=symbol)
         continue;
      if(OrderGetString(ORDER_COMMENT)!=comment)
         continue;
      return ticket;
     }
   return 0;
  }

string BuildSnapshotState(int &position_count,int &order_count)
  {
   string position_records="";
   string order_records="";
   position_count=0;
   order_count=0;

   if(CopyPositions)
     {
      for(int i=0;i<PositionsTotal();i++)
        {
         ulong ticket=PositionGetTicket(i);
         if(ticket==0 || !PositionSelectByTicket(ticket))
            continue;

         string symbol=PositionGetString(POSITION_SYMBOL);
         if(!IsMappedMasterSymbol(symbol))
            continue;

         if(position_records!="")
            position_records+=";";
         position_records+=StringFormat("%s^%s^%.8f^%d^%.8f^%.8f",
                                        LongToText((long)ticket),
                                        symbol,
                                        PositionGetDouble(POSITION_VOLUME),
                                        (int)PositionGetInteger(POSITION_TYPE),
                                        CopyStopLoss ? PositionGetDouble(POSITION_SL) : 0.0,
                                        CopyTakeProfit ? PositionGetDouble(POSITION_TP) : 0.0);
         position_count++;
        }
     }

   if(CopyPendingOrders)
     {
      for(int i=0;i<OrdersTotal();i++)
        {
         ulong ticket=OrderGetTicket(i);
         if(ticket==0 || !OrderSelect(ticket))
            continue;

         ENUM_ORDER_TYPE order_type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         if(!OrderTypeIsPending(order_type))
            continue;

         string symbol=OrderGetString(ORDER_SYMBOL);
         if(!IsMappedMasterSymbol(symbol))
            continue;

         if(order_records!="")
            order_records+=";";
         order_records+=StringFormat("%s^%s^%.8f^%d^%.8f^%.8f^%.8f^%.8f^%I64d",
                                     LongToText((long)ticket),
                                     symbol,
                                     OrderGetDouble(ORDER_VOLUME_INITIAL),
                                     (int)order_type,
                                     OrderGetDouble(ORDER_PRICE_OPEN),
                                     OrderGetDouble(ORDER_PRICE_STOPLIMIT),
                                     CopyStopLoss ? OrderGetDouble(ORDER_SL) : 0.0,
                                     CopyTakeProfit ? OrderGetDouble(ORDER_TP) : 0.0,
                                     CopyExpirations ? (long)OrderGetInteger(ORDER_TIME_EXPIRATION) : 0);
         order_count++;
        }
     }

   return StringFormat("%d|%s|%d|%s",
                       position_count,
                       EncodeBlob(position_records),
                       order_count,
                       EncodeBlob(order_records));
  }

string BuildSnapshotLine(const string state,const int position_count,const int order_count)
  {
   string parts[];
   string position_blob=EMPTY_BLOB;
   string order_blob=EMPTY_BLOB;
   if(StringSplit(state,'|',parts)>=4)
     {
      position_blob=parts[1];
      order_blob=parts[3];
     }

   g_publish_sequence++;
   return StringFormat("SNAPSHOT|%s|%s|%s|%s|%s|%d|%s|%d|%s",
                       PROTOCOL_VERSION,
                       g_channel_key,
                       LongToText((long)AccountInfoInteger(ACCOUNT_LOGIN)),
                       ULongToText(g_publish_sequence),
                       LongToText((long)TimeCurrent()),
                       position_count,
                       position_blob,
                       order_count,
                       order_blob);
  }

bool PublishSnapshotToFile(const string snapshot)
  {
   int file=FileOpen(g_transport_file_name,FILE_WRITE|FILE_TXT|FILE_COMMON|FILE_SHARE_READ);
   if(file==INVALID_HANDLE)
     {
      LogMessage(StringFormat("Unable to write %s. error=%d",g_transport_file_name,GetLastError()));
      return false;
     }
   FileWriteString(file,snapshot);
   FileClose(file);
   return true;
  }

bool ReadSnapshotFromFile(string &snapshot)
  {
   snapshot="";
   int file=FileOpen(g_transport_file_name,FILE_READ|FILE_TXT|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(file==INVALID_HANDLE)
      return false;
   snapshot=FileReadString(file);
   FileClose(file);
   return snapshot!="";
  }

bool LoadRemotePositions(const string blob,RemotePosition &positions[],bool &all_symbols_resolved)
  {
   ArrayResize(positions,0);
   all_symbols_resolved=true;
   string decoded=DecodeBlob(blob);
   if(decoded=="")
      return true;

   string items[];
   int item_count=StringSplit(decoded,';',items);
   for(int i=0;i<item_count;i++)
     {
      string columns[];
      if(StringSplit(items[i],'^',columns)<6)
         continue;

      string slave_symbol=FindSlaveSymbol(columns[1]);
      if(slave_symbol=="")
        {
         all_symbols_resolved=false;
         LogMessage(StringFormat("Could not resolve slave symbol for master symbol %s",columns[1]));
         continue;
        }

      int size=ArraySize(positions);
      ArrayResize(positions,size+1);
      positions[size].master_ticket=StringToInteger(columns[0]);
      positions[size].master_symbol=columns[1];
      positions[size].slave_symbol=slave_symbol;
      positions[size].volume=StringToDouble(columns[2]);
      positions[size].position_type=(ENUM_POSITION_TYPE)StringToInteger(columns[3]);
      positions[size].sl=NormalizePriceForSymbol(slave_symbol,StringToDouble(columns[4]));
      positions[size].tp=NormalizePriceForSymbol(slave_symbol,StringToDouble(columns[5]));
     }
   return true;
  }

bool LoadRemoteOrders(const string blob,RemoteOrder &orders[],bool &all_symbols_resolved)
  {
   ArrayResize(orders,0);
    all_symbols_resolved=true;
   string decoded=DecodeBlob(blob);
   if(decoded=="")
      return true;

   string items[];
   int item_count=StringSplit(decoded,';',items);
   for(int i=0;i<item_count;i++)
     {
      string columns[];
      if(StringSplit(items[i],'^',columns)<9)
         continue;

      string slave_symbol=FindSlaveSymbol(columns[1]);
      if(slave_symbol=="")
        {
         all_symbols_resolved=false;
         LogMessage(StringFormat("Could not resolve slave pending-order symbol for master symbol %s",columns[1]));
         continue;
        }

      ENUM_ORDER_TYPE order_type=(ENUM_ORDER_TYPE)StringToInteger(columns[3]);
      if(!OrderTypeIsPending(order_type))
         continue;

      int size=ArraySize(orders);
      ArrayResize(orders,size+1);
      orders[size].master_ticket=StringToInteger(columns[0]);
      orders[size].master_symbol=columns[1];
      orders[size].slave_symbol=slave_symbol;
      orders[size].volume=StringToDouble(columns[2]);
      orders[size].order_type=order_type;
      orders[size].price=NormalizePriceForSymbol(slave_symbol,StringToDouble(columns[4]));
      orders[size].stop_limit=NormalizePriceForSymbol(slave_symbol,StringToDouble(columns[5]));
      orders[size].sl=NormalizePriceForSymbol(slave_symbol,StringToDouble(columns[6]));
      orders[size].tp=NormalizePriceForSymbol(slave_symbol,StringToDouble(columns[7]));
      orders[size].expiration=(datetime)StringToInteger(columns[8]);
     }
   return true;
  }

bool EnsurePositionMatches(const RemotePosition &remote)
  {
   string comment=BuildEntityComment("P",remote.master_ticket);
   ulong ticket=FindSlavePositionTicket(remote.slave_symbol,comment);
   double target_volume=NormalizeVolumeForSymbol(remote.slave_symbol,remote.volume);

   if(ticket!=0 && PositionSelectByTicket(ticket))
     {
      ENUM_POSITION_TYPE current_type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double current_volume=PositionGetDouble(POSITION_VOLUME);
      if(current_type!=remote.position_type || VolumesDifferent(remote.slave_symbol,current_volume,target_volume))
        {
         if(!trade.PositionClose(ticket))
            return false;
         ticket=0;
        }
      else
        {
         double current_sl=PositionGetDouble(POSITION_SL);
         double current_tp=PositionGetDouble(POSITION_TP);
         if(PricesDifferent(remote.slave_symbol,current_sl,remote.sl) || PricesDifferent(remote.slave_symbol,current_tp,remote.tp))
            return trade.PositionModify(ticket,remote.sl,remote.tp);
         return true;
        }
     }

   if(remote.position_type==POSITION_TYPE_BUY)
      return trade.Buy(target_volume,remote.slave_symbol,remote.sl,remote.tp,comment);
   if(remote.position_type==POSITION_TYPE_SELL)
      return trade.Sell(target_volume,remote.slave_symbol,remote.sl,remote.tp,comment);
   return false;
  }

bool EnsureOrderMatches(const RemoteOrder &remote)
  {
   string comment=BuildEntityComment("O",remote.master_ticket);
   ulong ticket=FindSlaveOrderTicket(remote.slave_symbol,comment);
   double target_volume=NormalizeVolumeForSymbol(remote.slave_symbol,remote.volume);

   if(ticket!=0 && OrderSelect(ticket))
     {
      ENUM_ORDER_TYPE current_type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      double current_volume=OrderGetDouble(ORDER_VOLUME_INITIAL);
      if(current_type!=remote.order_type || VolumesDifferent(remote.slave_symbol,current_volume,target_volume))
        {
         if(!trade.PendingDelete(ticket))
            return false;
         ticket=0;
        }
      else
        {
         double current_price=OrderGetDouble(ORDER_PRICE_OPEN);
         double current_stop_limit=OrderGetDouble(ORDER_PRICE_STOPLIMIT);
         double current_sl=OrderGetDouble(ORDER_SL);
         double current_tp=OrderGetDouble(ORDER_TP);
         datetime current_expiration=(datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
         if(PricesDifferent(remote.slave_symbol,current_price,remote.price) ||
            PricesDifferent(remote.slave_symbol,current_stop_limit,remote.stop_limit) ||
            PricesDifferent(remote.slave_symbol,current_sl,remote.sl) ||
            PricesDifferent(remote.slave_symbol,current_tp,remote.tp) ||
            current_expiration!=remote.expiration)
            return trade.PendingModify(ticket,remote.slave_symbol,remote.price,remote.stop_limit,remote.sl,remote.tp,remote.expiration);
         return true;
        }
     }

   return trade.PendingCreate(remote.order_type,target_volume,remote.slave_symbol,remote.price,remote.stop_limit,remote.sl,remote.tp,remote.expiration,comment);
  }

void CleanupMissingSlavePositions(const long &active_master_tickets[])
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetInteger(POSITION_MAGIC)!=MagicNumber)
         continue;
      if(!IsMappedSlaveSymbol(PositionGetString(POSITION_SYMBOL)))
         continue;

      string comment=PositionGetString(POSITION_COMMENT);
      if(!IsCopiedCommentForChannel(comment) || ExtractEntityTypeFromComment(comment)!="P")
         continue;

      long master_ticket=ExtractMasterTicketFromComment(comment);
      if(master_ticket<0 || ContainsMasterTicket(active_master_tickets,master_ticket))
         continue;

      if(trade.PositionClose(ticket))
         LogMessage(StringFormat("Closed slave position %I64u for removed master ticket %s",ticket,LongToText(master_ticket)));
     }
  }

void CleanupMissingSlaveOrders(const long &active_master_tickets[])
  {
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0 || !OrderSelect(ticket))
         continue;
      if(OrderGetInteger(ORDER_MAGIC)!=MagicNumber)
         continue;
      if(!IsMappedSlaveSymbol(OrderGetString(ORDER_SYMBOL)))
         continue;

      string comment=OrderGetString(ORDER_COMMENT);
      if(!IsCopiedCommentForChannel(comment) || ExtractEntityTypeFromComment(comment)!="O")
         continue;

      long master_ticket=ExtractMasterTicketFromComment(comment);
      if(master_ticket<0 || ContainsMasterTicket(active_master_tickets,master_ticket))
         continue;

      if(trade.PendingDelete(ticket))
         LogMessage(StringFormat("Deleted slave pending order %I64u for removed master ticket %s",ticket,LongToText(master_ticket)));
     }
  }

void InitializeSlaveStartBaseline(const string position_blob,const string order_blob,const long source_account,const ulong sequence)
  {
   ExtractMasterTicketsFromBlob(position_blob,g_ignored_master_position_tickets);
   ExtractMasterTicketsFromBlob(order_blob,g_ignored_master_order_tickets);

   if(ClearCopiedTradesOnSlaveStart)
     {
      long empty_tickets[];
      ArrayResize(empty_tickets,0);
      if(CopyPositions)
         CleanupMissingSlavePositions(empty_tickets);
      if(CopyPendingOrders)
         CleanupMissingSlaveOrders(empty_tickets);
     }

   g_last_source_account=source_account;
   g_last_applied_sequence=sequence;
   g_slave_start_baseline_ready=true;

   LogMessage(StringFormat("Slave baseline created. Ignoring existing master trades on startup: positions=%d orders=%d.",
                           ArraySize(g_ignored_master_position_tickets),
                           ArraySize(g_ignored_master_order_tickets)));
   if(ClearCopiedTradesOnSlaveStart)
      LogMessage("Existing copied slave trades for this channel were cleared. Only new master trades will sync from now on.");
  }

void HandleSlaveSnapshot(const string snapshot_line)
  {
   string line=TrimString(snapshot_line);
   if(line=="")
      return;

   string parts[];
   if(StringSplit(line,'|',parts)<10)
     {
      LogMessage("Ignored malformed snapshot.");
      return;
     }

   if(parts[0]!="SNAPSHOT" || parts[1]!=PROTOCOL_VERSION || parts[2]!=g_channel_key)
      return;

   long source_account=StringToInteger(parts[3]);
   ulong sequence=(ulong)StringToInteger(parts[4]);
   if(source_account==g_last_source_account && sequence<=g_last_applied_sequence)
      return;

   if(!g_slave_start_baseline_ready)
     {
      if(!SyncExistingMasterTradesOnSlaveStart)
        {
         InitializeSlaveStartBaseline(parts[7],parts[9],source_account,sequence);
         return;
        }

      g_slave_start_baseline_ready=true;
      LogMessage("Slave startup sync is enabled. Existing master trades are allowed to sync.");
     }

   string schedule_reason="";
   if(!SlaveCopyAllowedBySchedule(schedule_reason))
      return;

   RemotePosition remote_positions[];
   RemoteOrder remote_orders[];
   bool position_symbols_resolved=true;
   bool order_symbols_resolved=true;
   LoadRemotePositions(parts[7],remote_positions,position_symbols_resolved);
   LoadRemoteOrders(parts[9],remote_orders,order_symbols_resolved);

   long active_position_tickets[];
   long active_order_tickets[];
   ArrayResize(active_position_tickets,0);
   ArrayResize(active_order_tickets,0);
   bool snapshot_applied=true;
   if(!position_symbols_resolved || !order_symbols_resolved)
      snapshot_applied=false;

   string trade_reason="";
   if(!SlaveTradeAllowed(trade_reason))
     {
      LogMessage(StringFormat("Snapshot %s from master %s is waiting because the slave terminal is not allowed to trade yet.",
                              ULongToText(sequence),
                              LongToText(source_account)));
      return;
     }

   if(CopyPositions)
     {
      for(int i=0;i<ArraySize(remote_positions);i++)
        {
         if(!SyncExistingMasterTradesOnSlaveStart && ContainsMasterTicket(g_ignored_master_position_tickets,remote_positions[i].master_ticket))
           {
            if(!ClearCopiedTradesOnSlaveStart)
               AddMasterTicket(active_position_tickets,remote_positions[i].master_ticket);
            continue;
           }
         AddMasterTicket(active_position_tickets,remote_positions[i].master_ticket);
         if(EnsurePositionMatches(remote_positions[i]))
            LogMessage(StringFormat("Synced position from master ticket %s to %s",LongToText(remote_positions[i].master_ticket),remote_positions[i].slave_symbol));
         else
           {
            snapshot_applied=false;
            LogMessage(StringFormat("Retrying position sync later for master ticket %s on %s",LongToText(remote_positions[i].master_ticket),remote_positions[i].slave_symbol));
           }
        }
      CleanupMissingSlavePositions(active_position_tickets);
     }

   if(CopyPendingOrders)
     {
      for(int i=0;i<ArraySize(remote_orders);i++)
        {
         if(!SyncExistingMasterTradesOnSlaveStart && ContainsMasterTicket(g_ignored_master_order_tickets,remote_orders[i].master_ticket))
           {
            if(!ClearCopiedTradesOnSlaveStart)
               AddMasterTicket(active_order_tickets,remote_orders[i].master_ticket);
            continue;
           }
         AddMasterTicket(active_order_tickets,remote_orders[i].master_ticket);
         if(EnsureOrderMatches(remote_orders[i]))
            LogMessage(StringFormat("Synced pending order from master ticket %s to %s",LongToText(remote_orders[i].master_ticket),remote_orders[i].slave_symbol));
         else
           {
            snapshot_applied=false;
            LogMessage(StringFormat("Retrying pending-order sync later for master ticket %s on %s",LongToText(remote_orders[i].master_ticket),remote_orders[i].slave_symbol));
           }
        }
      CleanupMissingSlaveOrders(active_order_tickets);
     }

   if(snapshot_applied)
     {
      g_last_source_account=source_account;
      g_last_applied_sequence=sequence;
     }
   else
      LogMessage(StringFormat("Snapshot %s from master %s not fully applied yet. The slave will retry the same snapshot.",ULongToText(sequence),LongToText(source_account)));
  }

void PublishMasterSnapshot()
  {
   int position_count=0;
   int order_count=0;
   string state=BuildSnapshotState(position_count,order_count);
   if(state==g_last_master_state)
      return;

   string snapshot=BuildSnapshotLine(state,position_count,order_count);
   if(PublishSnapshotToFile(snapshot))
      g_last_master_state=state;
  }

void PullSlaveSnapshot()
  {
   string snapshot="";
   if(ReadSnapshotFromFile(snapshot))
     {
      g_last_slave_snapshot=snapshot;
      HandleSlaveSnapshot(snapshot);
     }
  }

int OnInit()
  {
   g_channel_key=SanitizeIdentifier(TrimString(ChannelId));
   g_transport_file_name=BuildTransportFileName();

   if(!ParseSymbolMappings())
      return INIT_PARAMETERS_INCORRECT;
   if(!ParseScheduleRules())
      return INIT_PARAMETERS_INCORRECT;

   if(Mode==MODE_SLAVE)
      trade.SetExpertMagicNumber((ulong)MagicNumber);

   EventSetMillisecondTimer(TimerIntervalMs);
   if(Mode==MODE_SLAVE)
     {
      string trade_reason="";
      SlaveTradeAllowed(trade_reason);
      string schedule_reason="";
      SlaveCopyAllowedBySchedule(schedule_reason);
      ResolveTimeBasedLotMultiplier();
      if(!EnableSlaveTimeSchedule)
        {
         LogMessage("Slave copy schedule is OFF. Enable EnableSlaveTimeSchedule to use weekday and copy-stop filters.");
         if(HasActiveLotMultiplierSchedule())
            LogMessage("Lot multiplier scheduling is still active because a lot window or lot rule is configured.");
        }
     }
   LogMessage(StringFormat("Initialized. mode=%s channel=%s mappings=%d file=%s",
                           Mode==MODE_MASTER ? "MASTER" : "SLAVE",
                           g_channel_key,
                           ArraySize(g_symbol_maps),
                           g_transport_file_name));
   LogMessage("EA-only sync enabled. One master can feed multiple slave accounts through the shared common file.");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

void OnTimer()
  {
   if(Mode==MODE_MASTER)
      PublishMasterSnapshot();
   else
      PullSlaveSnapshot();
  }

void OnTrade()
  {
   if(Mode==MODE_MASTER && PublishOnTradeEvents)
      PublishMasterSnapshot();
  }

void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
  {
   if(Mode==MODE_MASTER && PublishOnTradeEvents)
      PublishMasterSnapshot();
  }

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
  {
  }
