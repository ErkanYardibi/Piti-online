# PiTi — hesap silme uygulama kapsamı

Durum: kaynak kod üzerinde veri kapsamı incelemesi; çalışan silme özelliği değil.
Canlı veri okunmadı veya silinmedi. Başvuru öncesinde aşağıdaki akış gerçekten
uygulanıp ayrı ortamda doğrulanmalı.

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
