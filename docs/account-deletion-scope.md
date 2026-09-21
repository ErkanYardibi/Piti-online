# PiTi — hesap silme uygulama kapsamı

Durum: profil özeti, şifre doğrulaması, tekrarlanabilir talep kaydı ve durum API'si
uygulandı; kalıcı temizleme motoru henüz yok. Talep kabulü varsayılan kapalı.
Canlıda sadece tablo/sütun metaverisi okundu; kullanıcı içerikleri okunmadı ve
veri silinmedi. App Store için talep kaydı tek başına yeterli değil.

## Kaynakta doğrulanan bağımlılıklar

| Alan | Silme akışının kapsaması gereken kayıtlar |
| --- | --- |
| Kimlik ve oturum | Auth kullanıcı kaydı, oturumlar, profil, kullanıcı adı ve giriş bağlantıları. Eski erişim tokenıyla işlem engellenmeli. |
| PT–müşteri ilişkisi | clients ve bağlı seans, görev, mesaj, ölçüm, ödeme/geçmiş kayıtları. PT silinirken müşterilerin bağımsız Auth hesapları yanlışlıkla silinmemeli. |
| Fotoğraf ve mesaj eki | chat-media nesneleri Storage API üzerinden; JSON içinde tutulan fotoğraf ve dekont kopyaları da kapsama alınmalı. Sadece SQL satırı silmek dosyayı kaldırmaz. |
| Diğer hesapların kopyaları | account_state ve client_history JSON verilerindeki ilgili kişisel bilgiler; diğer kullanıcıya ait bağımsız veriler korunmalı. |
| PT geçişi | trainer_transfers.snapshot, transfer_notifications ve private transfer_invitations. Bu kayıtların bazı kimlik alanlarında FK yok; Auth cascade tek başına yeterli değil. |
| Kapalı ilişki koruması | trainer-transfer.sql içindeki protect_closed_relationship tetikleyicisi eski ilişki verisinin silinmesini engelliyor. İstemcinin kullanamayacağı dar, sunucu kontrollü silme yolu tasarlanmalı. |
| Push | Oturuma bağlı cihazlar, teslim kuyruğu ve kullanıcı bildirim tercihleri. |
| Yönetim | account_audit, hesap işlemleri ve hesap kontrol kayıtları; kişisel veri/saklama kapsamı incelenmeli. |
| Kurtarma kopyaları | daily-recovery-copies.sql public tabloları JSON olarak kopyalıyor. Silinen kişinin geri yüklemede yeniden oluşmasını önleyen süreç gerekli. Mevcut sınır son 7 başarılı kopyadır; kesin 7 gün değildir. |
| Olay yedekleri | Şema incelemesinde ayrıca piti_private.incident_backups bulundu. Günlük kurtarma kopyalarından ayrı ele alınmalı. |

## Uygulanacak akış

1. Profilde bulunabilir “Hesabımı Sil” seçeneği ve rolüne uygun sonuç açıklaması.
2. Hesap sahibinin yeniden kimlik doğrulaması ve açık silme onayı; hedef kullanıcı
   sunucuda doğrulanmış oturumdan türetilir. DEMO bu endpoint'i çağırmaz.
3. Onaylanan silme işini kalıcı/idempotent kaydetme, hesabın erişimini ve yeni
   yazıları durdurma. İşlem yarıda kalırsa güvenli biçimde devam edebilmeli.
4. Storage nesnelerini ve ilişkili verileri kapsam listesine göre temizleme;
   eski PT ilişkisindeki koruma ve diğer hesaplardaki kopyaları ele alma.
5. Auth hesabını silme, kalan referansları doğrulama, kullanıcıya gerçek sonucu
   bildirme. Yalnızca talep kaydı oluşturulunca “hesabın silindi” yazılmamalı.
6. Kurtarma sırasında silinmiş hesapları yeniden yaratmama; bu davranışı ayrı
   restore testiyle doğrulama.

Finansal kayıtlar, güvenlik kayıtları ve yedekler için hangi bilgilerin hangi
süreyle tutulacağı henüz belirlenmedi. Bu belge bir yasal saklama süresi veya
uygunluk iddiası oluşturmaz. Kullanıcıya gösterilecek silme açıklaması gerçek
saklama uygulamasıyla eşleşmeden özellik yayına alınmamalı.

## Ortak geçmiş kararı — 21 Eylül 2026

Ürün sahibi kararı: PT hesabı silindiğinde müşterinin seans ve ödeme geçmişi
tarihsel bilgi olarak korunacak. Müşterinin bağımsız hesabı korunur; yeni PT
arşivi göremez. Arşiv, yeni ilişkiye paket/seans hakkı veya borç aktarmaz.

`20260921190901_member_retained_history.sql` bu kararın arşiv katmanıdır.
Sunucunun çağırabildiği yakalama işlemi yalnızca `processing` durumundaki,
hesabı askıya alınmış PT silme işi için çalışır. Mevcut müşteriler ile daha önce
PT değiştirmiş müşterilerin transfer snapshot'larını kapsar. Tekrarlanan çağrı
aynı arşivi değiştirmez. Hesabı olmayan manuel müşteriye arşiv hesabı yaratmaz.

Arşiv müşteri Auth hesabına bağlıdır, PT Auth hesabına bağlı değildir. Müşteri
kendi hesabını sildiğinde kendi arşivi de silinir. Okuma RPC'si geçerli oturumla
yalnızca çağıranın kayıtlarını döndürür; istemcilerin tabloya doğrudan okuma/yazma
yetkisi yoktur. PT'im ekranında salt okunur, isteğe bağlı yüklenen görünüm vardır.

Seans tarih/durumları, paketler, ödemeler, seans ücretleri, tahsilatlar, eski
paket/ödeme özetleri izin verilen alanlarla alınır. PT profili, mesaj, sağlık
ölçümü, serbest not/açıklama ve dekont/dosya yolu kopyalanmaz. Paket ve antrenman
başlığı gibi kullanıcı metinleri yine kişisel bilgi içerebilir; bu alan seçimi
tam anonimleştirme veya yasal uygunluk iddiası değildir.

Bu katman kendi başına PT bağlantısını kesmez, yeni müşteri kaydı yaratmaz,
hesap silmez ve talebi tamamlandı işaretlemez. Temizleme motoru arşivden önce
ilişkiye ait tüm yazıları (müşterinin yazıları dahil) durdurmalı; arşiv sayısını
doğrulamalı; eski transfer snapshot'larını ve diğer kopyaları temizlemeli; ardından
müşteriyi yeni PT'ye bağlanabilir duruma getirmelidir. Bu bütünleşik akış ve
Storage/yedek temizliği bitene kadar silme kabulü kapalı kalır.

## Bu aşamadaki doğrulama

Altı Edge Function testi, dört ekran testi ve geçici Postgres testi geçti.
Şifre doğrulaması taklit Auth yanıtlarıyla test edildi; gerçek bir kullanıcıyla
giriş veya silme yapılmadı. Testler yetki, oturum, yanlış hesap, tekrar, özet
değişimi, gizli durum anahtarı, kapalı servis ve hatalı başarı mesajlarını kapsar.
Gerçek dosya/veri temizleme ve yedekten geri yükleme testleri hâlâ açıktır.

Ek arşiv testleri geçici PostgreSQL ve jsdom üzerinde geçti: mevcut/eski müşteri
sahipliği, yeni PT'den izolasyon, tekrar, alan sınırları, tahsilatlar, PT Auth
silindikten sonra korunma, müşteri silindiğinde yalnızca kendi arşivinin kalkması,
iptal edilmiş oturum, ekran hesap değişimi ve güvenli metin gösterimi. Test
şeması tüm canlı bağımlılıkları içermez; bu bir üretim hesabı silme testi değildir.

## Kabul testleri

- Müşteri silme; başka PT ve müşterinin kayıtlarının korunması.
- PT silme; müşterilerin kendi hesaplarına erişiminin korunması.
- PT değiştirmiş müşteri; kapalı ilişki, geçiş snapshot'ı ve dosyaların kapsamı.
- Sahte hedef kullanıcı, süresi dolmuş/revoke edilmiş oturum, DEMO ve eşzamanlı yazı.
- Storage/Auth hatası sonrası tekrar; yarım işlemde hatalı başarı mesajı olmaması.
- Eski tokenla okuma/yazma ve push alımının engellenmesi.
- Kurtarma kopyası geri yüklendiğinde silinen hesabın geri gelmemesi.

Apple kaynağı: [Uygulama içinden hesap silme](https://developer.apple.com/support/offering-account-deletion-in-your-app/).
Supabase kaynağı: [Auth kullanıcı silme](https://supabase.com/docs/reference/javascript/auth-admin-deleteuser).
