//+------------------------------------------------------------------+
//|                                              fx_trade_copper.mq5 |
//|                          Copyright 2024-2026, FX Trade Copper     |
//|                                         https://www.allanmaug.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024-2026, FX Trade Copper"
#property link      "https://www.allanmaug.com"
#property version   "3.12"
#property strict

#define PROTOCOL_VERSION "2"
#define COMMENT_PREFIX "TC"
#define TELEGRAM_COMMENT_PREFIX "t.me/fx_bot_master"
#define BRANDED_COMMENT_PREFIX "fx_bot_master"
#define COMPACT_COMMENT_PREFIX "FXC"
#define MAX_TRADE_COMMENT_LENGTH 31
#define COMMENT_CHANNEL_TAG_LENGTH 4
#define LEGACY_COMMENT_CHANNEL_TAG_LENGTH 6
#define EMPTY_BLOB "-"

#include "fx_trade_copper_redis_module.mqh"

enum ENUM_MODE
  {
   MODE_MASTER,
   MODE_SLAVE
  };

input ENUM_MODE Mode = MODE_SLAVE;
input string ChannelId = "default";
input string SymbolMappings = "";
input string CopyOnlySymbols = "";
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
input bool EnableRedisHttpExport = false;
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

struct SymbolMapEntry
  {
   string master_symbol;
   string slave_symbol;
  };

struct SymbolFilterEntry
  {
   string value;
  };

struct SymbolResolutionEntry
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
SymbolFilterEntry g_symbol_filters[];
SymbolResolutionEntry g_symbol_resolution_cache[];
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
CRedisHttpExporter g_redis_exporter;

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
      result+=CharToString((uchar)ch);
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

string ToLowerAscii(const string value)
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

bool IsAsciiLetterOrDigit(const int ch)
  {
   return (ch>='A' && ch<='Z') || (ch>='a' && ch<='z') || (ch>='0' && ch<='9');
  }

bool StringContainsDigits(const string value)
  {
   int length=StringLen(value);
   for(int i=0;i<length;i++)
     {
      int ch=StringGetCharacter(value,i);
      if(ch>='0' && ch<='9')
         return true;
     }
   return false;
  }

bool StringsEqualIgnoreCase(const string left,const string right)
  {
   return ToUpperAscii(TrimString(left))==ToUpperAscii(TrimString(right));
  }

string CompactSymbolKey(const string symbol)
  {
   string compact="";
   string normalized=ToUpperAscii(TrimString(symbol));
   int length=StringLen(normalized);
   for(int i=0;i<length;i++)
     {
      int ch=StringGetCharacter(normalized,i);
      if(IsAsciiLetterOrDigit(ch))
         compact+=CharToString((uchar)ch);
     }
   return compact;
  }

int ContainedSymbolScore(const string candidate_compact,const string target_compact)
  {
   if(candidate_compact=="" || target_compact=="")
      return -1;

   int index=StringFind(candidate_compact,target_compact,0);
   if(index<0)
      return -1;

   string prefix=StringSubstr(candidate_compact,0,index);
   string suffix=StringSubstr(candidate_compact,index+StringLen(target_compact));
   if(StringContainsDigits(prefix) || StringContainsDigits(suffix))
      return -1;

   int extra_length=StringLen(prefix)+StringLen(suffix);
   if(extra_length>12)
      return -1;

   return 500-(extra_length*10);
  }

int GetSymbolSimilarityScore(const string candidate_symbol,const string target_symbol)
  {
   string candidate_trimmed=TrimString(candidate_symbol);
   string target_trimmed=TrimString(target_symbol);
   if(candidate_trimmed=="" || target_trimmed=="")
      return -1;

   string candidate_upper=ToUpperAscii(candidate_trimmed);
   string target_upper=ToUpperAscii(target_trimmed);
   if(candidate_upper==target_upper)
      return 3000;

   string candidate_normalized=NormalizeSymbolKey(candidate_trimmed);
   string target_normalized=NormalizeSymbolKey(target_trimmed);
   if(candidate_normalized!="" && candidate_normalized==target_normalized)
      return 2500;

   string candidate_compact=CompactSymbolKey(candidate_trimmed);
   string target_compact=CompactSymbolKey(target_trimmed);
   if(candidate_compact=="" || target_compact=="")
      return -1;

   if(candidate_compact==target_compact)
      return 2400;

   int contained_score=ContainedSymbolScore(candidate_compact,target_compact);
   if(contained_score>=0)
      return 2000+contained_score;

   contained_score=ContainedSymbolScore(target_compact,candidate_compact);
   if(contained_score>=0)
      return 2000+contained_score;

   return -1;
  }

int GetSymbolCompactExtraLength(const string candidate_symbol,const string target_symbol)
  {
   string candidate_compact=CompactSymbolKey(candidate_symbol);
   string target_compact=CompactSymbolKey(target_symbol);
   if(candidate_compact=="" || target_compact=="")
      return 1000;
   if(candidate_compact==target_compact)
      return 0;

   int index=StringFind(candidate_compact,target_compact,0);
   if(index>=0)
      return StringLen(candidate_compact)-StringLen(target_compact);

   index=StringFind(target_compact,candidate_compact,0);
   if(index>=0)
      return StringLen(target_compact)-StringLen(candidate_compact);

   return (int)MathAbs(StringLen(candidate_compact)-StringLen(target_compact))+100;
  }

int GetSymbolDecorationPenalty(const string candidate_symbol,const string target_symbol)
  {
   string candidate_trimmed=TrimString(candidate_symbol);
   string target_trimmed=TrimString(target_symbol);
   int penalty=(int)MathAbs(StringLen(candidate_trimmed)-StringLen(target_trimmed))*10;
   penalty+=GetSymbolCompactExtraLength(candidate_trimmed,target_trimmed)*100;

   int length=StringLen(candidate_trimmed);
   for(int i=0;i<length;i++)
     {
      int ch=StringGetCharacter(candidate_trimmed,i);
      if(!IsAsciiLetterOrDigit(ch))
         penalty+=5;
      if(ch=='.')
         penalty+=20;
     }

   return penalty;
  }

int GetSymbolTradePreferenceScore(const string symbol)
  {
   int score=0;
   ENUM_SYMBOL_TRADE_MODE trade_mode=(ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(symbol,SYMBOL_TRADE_MODE);
   switch(trade_mode)
     {
      case SYMBOL_TRADE_MODE_FULL:
         score+=400;
         break;
      case SYMBOL_TRADE_MODE_LONGONLY:
      case SYMBOL_TRADE_MODE_SHORTONLY:
         score+=250;
         break;
      case SYMBOL_TRADE_MODE_CLOSEONLY:
         score+=50;
         break;
      case SYMBOL_TRADE_MODE_DISABLED:
      default:
         score-=400;
         break;
     }

   if((bool)SymbolInfoInteger(symbol,SYMBOL_SELECT))
      score+=200;
   if((bool)SymbolInfoInteger(symbol,SYMBOL_VISIBLE))
      score+=100;
   if((bool)SymbolInfoInteger(symbol,SYMBOL_CUSTOM))
      score-=300;

   return score;
  }

bool IsBetterBrokerSymbolCandidate(const string candidate_symbol,
                                   const string best_symbol,
                                   const string symbol_template,
                                   const int candidate_score,
                                   const int best_score)
  {
   if(best_symbol=="" || best_score<0)
      return true;

   int candidate_trade_score=GetSymbolTradePreferenceScore(candidate_symbol);
   int best_trade_score=GetSymbolTradePreferenceScore(best_symbol);
   int candidate_penalty=GetSymbolDecorationPenalty(candidate_symbol,symbol_template);
   int best_penalty=GetSymbolDecorationPenalty(best_symbol,symbol_template);

   bool candidate_strong_match=(candidate_score>=2400);
   bool best_strong_match=(best_score>=2400);
   if(candidate_strong_match && best_strong_match)
     {
      if(candidate_trade_score!=best_trade_score)
         return candidate_trade_score>best_trade_score;
      if(candidate_penalty!=best_penalty)
         return candidate_penalty<best_penalty;
     }

   if(candidate_score!=best_score)
      return candidate_score>best_score;
   if(candidate_trade_score!=best_trade_score)
      return candidate_trade_score>best_trade_score;
   if(candidate_penalty!=best_penalty)
      return candidate_penalty<best_penalty;

   return StringLen(TrimString(candidate_symbol))<StringLen(TrimString(best_symbol));
  }

bool StartsWithText(const string value,const string prefix)
  {
   return StringSubstr(value,0,StringLen(prefix))==prefix;
  }

string TrimTrailingSlashes(const string value)
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

string EnsureLeadingSlash(const string value)
  {
   if(value=="")
      return "";
   if(StringGetCharacter(value,0)=='/')
      return value;
   return "/"+value;
  }

string JoinUrl(const string base_url,const string path)
  {
   string trimmed_base=TrimTrailingSlashes(TrimString(base_url));
   string normalized_path=EnsureLeadingSlash(TrimString(path));
   if(trimmed_base=="")
      return normalized_path;
   if(normalized_path=="")
      return trimmed_base;
   return trimmed_base+normalized_path;
  }

string JsonEscape(const string value)
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

string JsonString(const string value)
  {
   return "\""+JsonEscape(value)+"\"";
  }

string JsonBool(const bool value)
  {
   return value ? "true" : "false";
  }

string DateTimeToIsoText(const datetime value)
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

datetime StartOfDay(const datetime value)
  {
   MqlDateTime parts={};
   if(!TimeToStruct(value,parts))
      return value;
   parts.hour=0;
   parts.min=0;
   parts.sec=0;
   return StructToTime(parts);
  }

bool ParseDateInput(const string text,const bool end_of_day,datetime &value)
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
   return GetSymbolSimilarityScore(left,right)>=2000;
  }

void AddUniqueText(string &values[],const string value)
  {
   string trimmed=TrimString(value);
   if(trimmed=="")
      return;

   for(int i=0;i<ArraySize(values);i++)
     {
      if(StringsEqualIgnoreCase(values[i],trimmed))
         return;
     }

   int size=ArraySize(values);
   ArrayResize(values,size+1);
   values[size]=trimmed;
  }

string GetCachedSlaveSymbol(const string master_symbol)
  {
   for(int i=0;i<ArraySize(g_symbol_resolution_cache);i++)
     {
      if(StringsEqualIgnoreCase(g_symbol_resolution_cache[i].master_symbol,master_symbol) ||
         SymbolsEquivalent(g_symbol_resolution_cache[i].master_symbol,master_symbol))
         return g_symbol_resolution_cache[i].slave_symbol;
     }
   return "";
  }

void CacheSlaveSymbol(const string master_symbol,const string slave_symbol)
  {
   if(TrimString(master_symbol)=="" || TrimString(slave_symbol)=="")
      return;

   for(int i=0;i<ArraySize(g_symbol_resolution_cache);i++)
     {
      if(StringsEqualIgnoreCase(g_symbol_resolution_cache[i].master_symbol,master_symbol) ||
         SymbolsEquivalent(g_symbol_resolution_cache[i].master_symbol,master_symbol))
        {
         g_symbol_resolution_cache[i].master_symbol=master_symbol;
         g_symbol_resolution_cache[i].slave_symbol=slave_symbol;
         return;
        }
     }

   int size=ArraySize(g_symbol_resolution_cache);
   ArrayResize(g_symbol_resolution_cache,size+1);
   g_symbol_resolution_cache[size].master_symbol=master_symbol;
   g_symbol_resolution_cache[size].slave_symbol=slave_symbol;
  }

void BuildSymbolLookupCandidates(const string master_symbol,const string template_symbol,string &candidates[])
  {
   ArrayResize(candidates,0);
   AddUniqueText(candidates,template_symbol);
   AddUniqueText(candidates,NormalizeSymbolKey(template_symbol));
   AddUniqueText(candidates,master_symbol);
   AddUniqueText(candidates,NormalizeSymbolKey(master_symbol));
   AddUniqueText(candidates,CompactSymbolKey(template_symbol));
   AddUniqueText(candidates,CompactSymbolKey(master_symbol));
  }

bool ParseCopyOnlySymbols()
  {
   ArrayResize(g_symbol_filters,0);

   string filter_text=TrimString(CopyOnlySymbols);
   if(filter_text=="")
      return true;

   string normalized=ReplaceString(filter_text,",",";");
   string items[];
   int item_count=StringSplit(normalized,';',items);
   if(item_count<=0)
      return false;

   for(int i=0;i<item_count;i++)
     {
      string value=TrimString(items[i]);
      if(value=="")
         continue;

      int size=ArraySize(g_symbol_filters);
      ArrayResize(g_symbol_filters,size+1);
      g_symbol_filters[size].value=value;
     }

   return ArraySize(g_symbol_filters)>0;
  }

bool HasSymbolCopyFilter()
  {
   return ArraySize(g_symbol_filters)>0;
  }

bool SymbolMatchesCopyFilter(const string symbol)
  {
   if(!HasSymbolCopyFilter())
      return true;

   for(int i=0;i<ArraySize(g_symbol_filters);i++)
     {
      if(GetSymbolSimilarityScore(symbol,g_symbol_filters[i].value)>=2000)
         return true;
     }

   return false;
  }

bool IsSymbolAllowedForCopy(const string master_symbol,const string slave_symbol="")
  {
   if(!HasSymbolCopyFilter())
      return true;

   if(SymbolMatchesCopyFilter(master_symbol))
      return true;

   if(slave_symbol!="" && SymbolMatchesCopyFilter(slave_symbol))
      return true;

   return false;
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
   config.log_prefix="FXTradeCopper";
   config.ea_name="FX Trade Copper";
   config.ea_version="3.12";
   config.mode_name=(Mode==MODE_MASTER) ? "MASTER" : "SLAVE";
   config.channel_id=g_channel_key;
   config.copy_positions=CopyPositions;
   config.copy_pending_orders=CopyPendingOrders;
   config.copy_stop_loss=CopyStopLoss;
   config.copy_take_profit=CopyTakeProfit;
   config.copy_expirations=CopyExpirations;
   config.volume_multiplier=VolumeMultiplier;
   config.enable_slave_time_schedule=EnableSlaveTimeSchedule;
   config.simple_lot_window=UseSimpleLotMultiplierWindow;
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
   ArrayResize(g_symbol_resolution_cache,0);
   string mapping_text=TrimString(SymbolMappings);
   if(mapping_text=="")
      return AutoMapByBaseSymbol;

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

   return ArraySize(g_symbol_maps)>0 || AutoMapByBaseSymbol;
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

string ResolveBrokerSymbolFromPool(const string symbol_template,const bool selected_only)
  {
   if(symbol_template=="")
      return "";

   string best_candidate="";
   int best_score=-1;
   int total=SymbolsTotal(selected_only);
   for(int i=0;i<total;i++)
     {
      string candidate=SymbolName(i,selected_only);
      int candidate_score=GetSymbolSimilarityScore(candidate,symbol_template);
      if(candidate_score<2000)
         continue;
      if(IsBetterBrokerSymbolCandidate(candidate,best_candidate,symbol_template,candidate_score,best_score))
        {
         best_score=candidate_score;
         best_candidate=candidate;
        }
     }

   if(best_score<2000)
      return "";

   if(SymbolSelect(best_candidate,true))
      return best_candidate;
   return best_candidate;
  }

string ResolveBrokerSymbol(const string symbol_template)
  {
   if(symbol_template=="")
      return "";

   if(SymbolSelect(symbol_template,true))
      return symbol_template;

   if(!AutoMapByBaseSymbol)
      return "";

   string resolved=ResolveBrokerSymbolFromPool(symbol_template,true);
   if(resolved!="")
      return resolved;

   return ResolveBrokerSymbolFromPool(symbol_template,false);
  }

string FindSlaveSymbol(const string master_symbol)
  {
   string cached_symbol=GetCachedSlaveSymbol(master_symbol);
   if(cached_symbol!="")
      return cached_symbol;

   string template_symbol=GetMappedSlaveSymbolTemplate(master_symbol);
   string candidates[];
   BuildSymbolLookupCandidates(master_symbol,template_symbol,candidates);

   for(int i=0;i<ArraySize(candidates);i++)
     {
      string resolved=ResolveBrokerSymbol(candidates[i]);
      if(resolved!="")
        {
         CacheSlaveSymbol(master_symbol,resolved);
         if(VerboseLogs && !StringsEqualIgnoreCase(resolved,master_symbol))
           {
            string source_hint=(StringsEqualIgnoreCase(candidates[i],template_symbol) && template_symbol!="")
                               ? StringFormat("template %s",template_symbol)
                               : StringFormat("alias %s",candidates[i]);
            LogMessage(StringFormat("Auto-detected slave symbol %s for master symbol %s using %s.",
                                    resolved,
                                    master_symbol,
                                    source_hint));
           }
         return resolved;
        }
     }

   return "";
  }

bool IsMappedMasterSymbol(const string symbol)
  {
   if(!IsSymbolAllowedForCopy(symbol))
      return false;
   return GetMappedSlaveSymbolTemplate(symbol)!="";
  }

bool IsMappedSlaveSymbol(const string symbol)
  {
   if(!IsSymbolAllowedForCopy(symbol))
      return false;

   for(int i=0;i<ArraySize(g_symbol_maps);i++)
     {
      if(g_symbol_maps[i].slave_symbol==symbol)
         return true;
      if(AutoMapByBaseSymbol && SymbolsEquivalent(g_symbol_maps[i].slave_symbol,symbol))
         return true;
     }

   return AutoMapByBaseSymbol;
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
   string ticket_token=EncodeTicketToken(master_ticket);
   string channel_token=ShortChannelTag();
   string preferred=StringFormat("%s|%s%s%s",TELEGRAM_COMMENT_PREFIX,entity_type,channel_token,ticket_token);
   if(StringLen(preferred)<=MAX_TRADE_COMMENT_LENGTH)
      return preferred;
   return StringFormat("%s|%s|%s|%s",COMPACT_COMMENT_PREFIX,LegacyShortChannelTag(),entity_type,ticket_token);
  }

string ChannelTagWithLength(const int length)
  {
   string channel_tag=ChannelTag();
   if(StringLen(channel_tag)<=length)
      return channel_tag;
   return StringSubstr(channel_tag,0,length);
  }

string ShortChannelTag()
  {
   return ChannelTagWithLength(COMMENT_CHANNEL_TAG_LENGTH);
  }

string LegacyShortChannelTag()
  {
   return ChannelTagWithLength(LEGACY_COMMENT_CHANNEL_TAG_LENGTH);
  }

int EncodedDigitValue(const int ch)
  {
   if(ch>='0' && ch<='9')
      return ch-'0';
   if(ch>='A' && ch<='Z')
      return ch-'A'+10;
   if(ch>='a' && ch<='z')
      return ch-'a'+36;
   return -1;
  }

string EncodedDigitText(const int digit)
  {
   if(digit<10)
      return CharToString((uchar)('0'+digit));
   if(digit<36)
      return CharToString((uchar)('A'+digit-10));
   return CharToString((uchar)('a'+digit-36));
  }

string EncodeTicketToken(const long master_ticket)
  {
   ulong value=(master_ticket<0) ? 0 : (ulong)master_ticket;
   if(value==0)
      return "0";

   string token="";
   while(value>0)
     {
      int digit=(int)(value%62);
      token=EncodedDigitText(digit)+token;
      value/=62;
     }
   return token;
  }

bool DecodeTicketToken(const string token,long &master_ticket)
  {
   master_ticket=-1;
   string normalized=TrimString(token);
   if(normalized=="")
      return false;

   ulong value=0;
   for(int i=0;i<StringLen(normalized);i++)
     {
      int digit=EncodedDigitValue(StringGetCharacter(normalized,i));
      if(digit<0)
         return false;
      value=(value*62)+(ulong)digit;
     }

   master_ticket=(long)value;
   return master_ticket>=0;
  }

bool ParseCopiedCommentForChannel(const string comment,string &entity_type,long &master_ticket)
  {
   entity_type="";
   master_ticket=-1;

   string trimmed=TrimString(comment);
   if(trimmed=="")
      return false;

   string telegram_prefix=StringFormat("%s|",TELEGRAM_COMMENT_PREFIX);
   if(StringFind(trimmed,telegram_prefix,0)==0)
     {
      string payload=StringSubstr(trimmed,StringLen(telegram_prefix));
      if(StringLen(payload)<1+COMMENT_CHANNEL_TAG_LENGTH+1)
         return false;

      entity_type=StringSubstr(payload,0,1);
      string channel_token=StringSubstr(payload,1,COMMENT_CHANNEL_TAG_LENGTH);
      string ticket_token=StringSubstr(payload,1+COMMENT_CHANNEL_TAG_LENGTH);
      if(ToUpperAscii(channel_token)!=ToUpperAscii(ShortChannelTag()))
         return false;
      return entity_type!="" && DecodeTicketToken(ticket_token,master_ticket);
     }

   string parts[];
   if(StringSplit(trimmed,'|',parts)<4)
      return false;

   string prefix=TrimString(parts[0]);
   if(prefix==COMMENT_PREFIX)
     {
      // Legacy format: TC|<full channel tag>|<entity>|<master ticket>
      if(ToUpperAscii(TrimString(parts[1]))!=ToUpperAscii(ChannelTag()))
         return false;
      entity_type=TrimString(parts[2]);
      master_ticket=StringToInteger(TrimString(parts[3]));
      return entity_type!="" && master_ticket>=0;
     }

   if(prefix==BRANDED_COMMENT_PREFIX)
     {
      string channel_token=TrimString(parts[2]);
      if(ToUpperAscii(channel_token)!=ToUpperAscii(ShortChannelTag()) &&
         ToUpperAscii(channel_token)!=ToUpperAscii(LegacyShortChannelTag()))
         return false;
      entity_type=TrimString(parts[1]);
      return entity_type!="" && DecodeTicketToken(parts[3],master_ticket);
     }

   if(prefix==COMPACT_COMMENT_PREFIX)
     {
      string channel_token=TrimString(parts[1]);
      if(ToUpperAscii(channel_token)!=ToUpperAscii(ShortChannelTag()) &&
         ToUpperAscii(channel_token)!=ToUpperAscii(LegacyShortChannelTag()))
         return false;
      entity_type=TrimString(parts[2]);
      return entity_type!="" && DecodeTicketToken(parts[3],master_ticket);
     }

   return false;
  }

bool IsCopiedCommentForChannel(const string comment)
  {
   string entity_type="";
   long master_ticket=-1;
   return ParseCopiedCommentForChannel(comment,entity_type,master_ticket);
  }

string ExtractEntityTypeFromComment(const string comment)
  {
   string entity_type="";
   long master_ticket=-1;
   if(!ParseCopiedCommentForChannel(comment,entity_type,master_ticket))
      return "";
   return entity_type;
  }

long ExtractMasterTicketFromComment(const string comment)
  {
   string entity_type="";
   long master_ticket=-1;
   if(!ParseCopiedCommentForChannel(comment,entity_type,master_ticket))
      return -1;
   return master_ticket;
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

ulong FindSlavePositionTicket(const string symbol,const long master_ticket)
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
      string entity_type="";
      long parsed_master_ticket=-1;
      if(!ParseCopiedCommentForChannel(PositionGetString(POSITION_COMMENT),entity_type,parsed_master_ticket))
         continue;
      if(entity_type!="P" || parsed_master_ticket!=master_ticket)
         continue;
      return ticket;
     }
   return 0;
  }

ulong FindSlaveOrderTicket(const string symbol,const long master_ticket)
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
      string entity_type="";
      long parsed_master_ticket=-1;
      if(!ParseCopiedCommentForChannel(OrderGetString(ORDER_COMMENT),entity_type,parsed_master_ticket))
         continue;
      if(entity_type!="O" || parsed_master_ticket!=master_ticket)
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
      if(slave_symbol!="" && !IsSymbolAllowedForCopy(columns[1],slave_symbol))
         continue;
      if(slave_symbol=="")
        {
         if(!IsSymbolAllowedForCopy(columns[1]))
            continue;
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
      if(slave_symbol!="" && !IsSymbolAllowedForCopy(columns[1],slave_symbol))
         continue;
      if(slave_symbol=="")
        {
         if(!IsSymbolAllowedForCopy(columns[1]))
            continue;
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
   ulong ticket=FindSlavePositionTicket(remote.slave_symbol,remote.master_ticket);
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
   ulong ticket=FindSlaveOrderTicket(remote.slave_symbol,remote.master_ticket);
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
   if(!ParseCopyOnlySymbols())
      return INIT_PARAMETERS_INCORRECT;
   if(!ParseScheduleRules())
      return INIT_PARAMETERS_INCORRECT;
   RedisHttpExportConfig redis_export_config;
   LoadRedisHttpExportConfig(redis_export_config);
   if(!g_redis_exporter.Initialize(redis_export_config))
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
      if(TrimString(SymbolMappings)=="")
         LogMessage("SymbolMappings is blank. Auto broker symbol detection is active, so common suffix and prefix symbols such as XAUUSD.m, XAUUSDm, or mXAUUSD can be matched automatically.");
      if(!EnableSlaveTimeSchedule)
        {
         LogMessage("Slave copy schedule is OFF. Enable EnableSlaveTimeSchedule to use weekday and copy-stop filters.");
         if(HasActiveLotMultiplierSchedule())
            LogMessage("Lot multiplier scheduling is still active because a lot window or lot rule is configured.");
        }
     }
   LogMessage(StringFormat("Initialized. mode=%s channel=%s mappings=%d symbol_filter=%d auto_map=%s file=%s",
                           Mode==MODE_MASTER ? "MASTER" : "SLAVE",
                           g_channel_key,
                           ArraySize(g_symbol_maps),
                           ArraySize(g_symbol_filters),
                           AutoMapByBaseSymbol ? "true" : "false",
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
   g_redis_exporter.MaybePublish();
  }

void OnTrade()
  {
   if(Mode==MODE_MASTER && PublishOnTradeEvents)
      PublishMasterSnapshot();
   if(EnableRedisHttpExport && RedisHttpPublishOnTradeEvents)
      g_redis_exporter.QueuePublish();
  }

void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
  {
   if(Mode==MODE_MASTER && PublishOnTradeEvents)
      PublishMasterSnapshot();
   if(EnableRedisHttpExport && RedisHttpPublishOnTradeEvents)
      g_redis_exporter.QueuePublish();
  }

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
  {
  }
