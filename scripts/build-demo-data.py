"""Rebuild the shared, fictional one-trainer / ten-client demo fixture."""
import json
from pathlib import Path
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo
from copy import deepcopy
# The explicit reference date makes this fixture reproducible.
anchor=date(2026,9,18)
monday=anchor-timedelta(days=anchor.weekday())
start=monday-timedelta(days=7)
def ds(d):return d.isoformat()
def ts(d,time='12:00'):return f'{ds(d)}T{time}:00+03:00'
names=['Ayşe Demir','Zeynep Aslan','Deniz Yılmaz','Emre Kaya','Elif Şahin','Can Arslan','Selin Aydın','Mert Aksoy','Derya Çelik','Burak Yıldız']
weights=[68.2,62.4,83.5,91.2,59.8,78.6,71.3,86.4,65.1,94.5]
waists=[79,73,92,100,70,87,83,95,76,103]
trainer={'name':'Mehmet Kaya','bio':'Birebir kuvvet ve kondisyon antrenmanları. Hafta içi 09.00–18.15.','specialties':'Kuvvet, kondisyon, hareketlilik','locations':[{'id':1,'name':'Lara Fitness Stüdyo','address':'Lara, Antalya'}],'photo':'','confirmHours':24}
s={'demoFixtureVersion':1,'demoReferenceDate':ds(anchor),'role':'pt','page':'dashboard','calCursor':ds(anchor.replace(day=1))+'T12:00:00.000Z','selectedDate':ds(anchor),'ptProfile':trainer,'manualCustomers':[],'demoCustomers':[],'customerAccounts':{},'events':[],'demoChat':{'messages':[],'tasks':[]},'invite':{'ptCode':'DEMO-PT-10','oneTimeCodes':[],'pending':[],'approved':[]},'customerArchiveView':'active','calendarCustomerFilter':'all','calendarShowArchived':False}
for key in ['testUsersVersion','sessionResultsVersion','futureSessionResultsVersion','futureDemoResultsVersion','demoResultDatesVersion','duplicateTestSessionsVersion','ptOffDedupeVersion']:s[key]=1
customers=[]
for i,name in enumerate(names):
 c={'id':f'demo-client-{i+1:02}','name':name,'initials':''.join(x[0] for x in name.split()),'weight':weights[i],'height':[165,168,178,182,162,176,170,180,167,185][i],'status':'active','archived':False,'photo':'','email':f'demo.client{i+1}@example.com','phone':'','blood':'','gender':'','testScenario':'Haftada 2 birebir seans'}
 customers.append(c)
 a={'customer':c,'package':{'name':'12 Seans / 30 Gün','price':7500,'start':ds(start),'end':ds(start+timedelta(days=30)),'expireDate':ds(start+timedelta(days=30)),'totalSessions':12,'usedSessions':0,'durationDays':30,'freezeDays':0,'status':'active','rule':'30 gün veya 12 seans; hangisi önce biterse'},'payment':{'status':'pending' if i in [2,6] else 'unpaid' if i==8 else 'approved','amount':7500,'method':'EFT/Havale','receipt':'','submitted':i!=8},'financeHistory':[],'messages':[],'tasks':[],'progressData':[],'unread':{'pt':0,'member':1},'memberTrainer':{'name':trainer['name'],'code':'DEMO-PT-10','status':'connected'}}
 for j,ago in enumerate([10,5,1]):
  d=anchor-timedelta(days=ago);a['progressData'].append({'id':f'measure-{i}-{j}','date':ds(d),'d':ds(d),'w':round(weights[i]+(2-j)*.4,1),'waist':waists[i]+(2-j),'source':'measurement_form','createdAt':ts(d,'08:00')})
 a['financeHistory'].append({'date':ds(start),'text':'Paket başlatıldı','detail':'12 seans / 30 gün · 7.500 TL'})
 if a['payment']['status']=='approved':a['financeHistory'].append({'date':ds(start),'text':'Ödeme onaylandı','detail':'7.500 TL · EFT/Havale'})
 if a['payment']['submitted']:a['payment']['submittedAt']=ds(start)
 s['customerAccounts'][c['id']]=a
# Two sessions per client each week, evenly spread across five workdays.
for week in range(4):
 for i,c in enumerate(customers):
  for visit in range(2):
   day=(i//2+visit*2)%5;d=start+timedelta(days=week*7+day)
   hour=(9 if visit==0 else 16);minute=15 if i%2 else 0;hour+=i%2
   time=f'{hour:02}:{minute:02}';end=f'{hour+1:02}:{minute:02}'
   past=d<anchor;status='completed' if past else 'planned';counts=past
   if week==0 and visit==1 and i in [3,7]:status='noshow';counts=i==3
   groups=['Göğüs','Omuz','Kol'] if visit==0 else ['Bacak','Sırt','Karın']
   e={'id':10000+week*100+i*2+visit,'customerId':c['id'],'customerName':c['name'],'createdBy':'pt','type':'session','date':ds(d),'time':time,'endTime':end,'title':'Üst Vücut Kuvvet' if visit==0 else 'Alt Vücut ve Sırt','muscleGroups':groups,'status':status,'counts':counts,'packageDebit':int(counts),'location':'Lara Fitness Stüdyo'}
   if status in ['completed','noshow']:
    e['resolvedAt']=ts(d,end);e['resolvedBy']='pt';e['confirmation']={'status':'accepted','createdAt':ts(d,end),'deadline':ts(d+timedelta(days=1),end)}
    a=s['customerAccounts'][c['id']];a['package']['usedSessions']+=int(counts)
    a['financeHistory'].append({'date':ds(d),'text':'Seans tamamlandı' if status=='completed' else 'No Show','detail':time+' · '+('Paketinden 1 seans düşüldü' if counts else 'Mazeretli; seans düşülmedi'),'eventId':e['id']})
   if week==2 and i==9 and visit==1:e.update(status='requested',createdBy='member:'+c['id'],title='PT Randevu Talebi')
   s['events'].append(e)
for week in range(4):
 for day in range(5):
  d=start+timedelta(days=week*7+day)
  if d>=anchor:s['events'].append({'id':20000+week*10+day,'createdBy':'pt','type':'availability','date':ds(d),'time':'12:00','endTime':'13:00','title':'Müsait','status':'open'})
 d=start+timedelta(days=week*7+6)
 s['events'].append({'id':21000+week,'createdBy':'pt','type':'off','date':ds(d),'time':'Tüm gün','title':'Çalışmıyor','status':'off'})
for i,c in enumerate(customers):
 def msg(mid,body,role='pt',sticker=None,d=anchor):
  s['demoChat']['messages'].append({'id':mid,'client_id':c['id'],'sender_id':'demo-pt' if role=='pt' else 'demo-member-'+c['id'],'sender_role':role,'body':body,'sticker':sticker,'created_at':ts(d,'08:00'),'read_at':ts(d,'08:10') if d<anchor else None})
 msg(f'welcome-{i}','Bu hafta iki seansımız takvimde. Görüşmek üzere!',d=anchor-timedelta(days=2));msg(f'reply-{i}','Teşekkürler hocam, takvimi kontrol ettim.','member',d=anchor-timedelta(days=2))
 for k,(title,sticker,kind) in enumerate([('Sabah aç karnına tartıl','weigh','kg'),('Bugünkü su tüketimini paylaş','water','litre'),('Öğle öğününü paylaş','meal','photo')]):
  mid=f'task-message-{i}-{k}';done=k==0 and i<4;d=anchor-timedelta(days=1) if done else anchor
  msg(mid,title,sticker=sticker,d=d)
  s['demoChat']['tasks'].append({'id':f'task-{i}-{k}','client_id':c['id'],'message_id':mid,'title':title,'due_at':ts(d,'20:00'),'response_type':kind,'status':'done' if done else 'open','result':str(weights[i]) if done else None,'completed_at':ts(d,'08:30') if done else None})
for c in customers[:4]:s['customerAccounts'][c['id']]['progressData'].pop()
s['customer']=customers[0];s['demoCustomers']=customers[1:];s['testPrimaryId']=customers[0]['id']
for k,v in s['customerAccounts'][s['testPrimaryId']].items():s[k]=deepcopy(v)
s['events'].sort(key=lambda e:(e['date'],e['time'],e['id']))
# Validate all booked intervals, including tentative requests, for a single trainer.
rows=sorted([e for e in s['events'] if e['type']=='session'],key=lambda e:(e['date'],e['time']))
for a,b in zip(rows,rows[1:]):assert a['date']!=b['date'] or a['endTime']<=b['time'],(a,b)
assert len(s['customerAccounts'])==10 and len(s['demoCustomers'])==9
for cid,a in s['customerAccounts'].items():assert a['package']['usedSessions']==sum(e.get('packageDebit',0) for e in rows if e['customerId']==cid)
Path('assets/demo-state.json').write_text(json.dumps(s,ensure_ascii=False,separators=(',',':')))
print(f'Validated: 1 PT, 10 clients, {len(rows)} sessions; no overlaps; package usage matches history.')
