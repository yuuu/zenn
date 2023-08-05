---
title: "RailsをバックエンドとしたSPAでのファイルアップロード機能の作り方に悩んだ話"
emoji: "📁"
type: "tech"
topics:
  - "aws"
  - "rails"
  - "react"
  - "ruby"
  - "s3"
published: true
published_at: "2021-02-24 07:05"
---

Ruby on RailsにはActive Storageと呼ばれるファイルアップロードをサポートする機能が用意されています。Railsだけでシステムを開発する際、これは非常に便利な機能です。

一方、SPAを作る場合ファイルアップロードの実装方法はいくつかの選択肢があります。ググってみても実装方針が人それぞれで、意見が分かれているように感じました。

そこで、それぞれの実装案を比較した上で、今回私が実装した署名付きURLを使った実装方法を解説したいと思います。

## 今回取り上げるシステム構成

今回はフロントエンドにReact(Next.js)を使い、バックエンドにAPIモードのRailsを利用しています。ファイルのアップロード先としてAWSのS3を利用します。

![](https://storage.googleapis.com/zenn-user-upload/dfz4mw9o88e8b5df8brkkur71owu)

## 実装案

### 案1. Railsのフォームヘルパーと使ったときと同様、FormDataを構築してPOSTする

Railsのレールをできる限り崩さず、フォームヘルパーを使ったときと同様のFormDataを作ってPOSTするという方法です。Railsの視点だと一番嬉しい方法かもしれませんが、フロントエンドの視点に立つとPOSTするデータはJSONとしたいです。

![](https://storage.googleapis.com/zenn-user-upload/tr567ilknplda1riij5pnsfy3v2w)

#### メリット

- 普段Railsを使うときと同様にActive Storageを使える

#### デメリット

- フロントエンド側でFormDataを作るのが面倒

### 案2. ファイルをJSONに埋め込んでPOSTする

POSTするファイルをbase64エンコードしてJSONにPOSTするのはどうでしょう？Rails側でbase64デコード処理が、フロントエンド側でbase64エンコード処理が必要となり、双方実装コストが高い方法です。

![](https://storage.googleapis.com/zenn-user-upload/xem7iq7cq1lqorit3yq0gyzv3ltb)

#### メリット

- Active Storageを使い続けられる

#### デメリット

- フロントエンド側でbase64エンコードするのが面倒
- Railsでbase64デコードが必要

### 案3. Active Storageのダイレクトアップロードを使用する

RailsのActive Storageには[ダイレクトアップロード](https://railsguides.jp/active_storage_overview.html#%E3%83%80%E3%82%A4%E3%83%AC%E3%82%AF%E3%83%88%E3%82%A2%E3%83%83%E3%83%97%E3%83%AD%E3%83%BC%E3%83%89)という機能が用意されています。これを使えばフロントエンド側からファイルをダイレクトにS3へアップロードし、Keyなどの必要な情報のみをRailsに渡すことができます。

![](https://storage.googleapis.com/zenn-user-upload/qcofzy4hs4nfu0lvrbwqgexvyvgh)

#### メリット

- RailsにファイルをPOSTしなくて良い

#### デメリット

- ダイレクトアップロード自体がRailsに依存している

### 案4. 署名付きURLを使って画像をS3に直接アップロードし、KeyのみPOSTする

S3は[署名付きURL](https://docs.aws.amazon.com/ja_jp/AmazonS3/latest/dev/PresignedUrlUploadObject.html)を使ったファイルのアップロードに対応しています。Railsから署名付きURLを発行することで、フロントエンド側でS3に直接ファイルをアップロードできます。案3と同様、アップロード後にKeyなどの必要な情報のみをRailsに渡します。

![](https://storage.googleapis.com/zenn-user-upload/lg2ym57b2927jf0jnkz3fjyyiix6)

#### メリット

- フロントエンド側がRailsに依存しない

#### デメリット

- Active Storageの恩恵を受けられない
- PUT先となる署名付きURLの発行処理を独自実装する必要がある

## 実装案の選定

「マイクロサービス化しやすい」というのはSPAを採用する動機の一つだと思っています。案1〜3は実装コスト的にもデメリットが大きいのですが「フロントエンドがRailsに依存した実装になっている点」がイマイチだと感じました。

このため、今回は案4で実装を進めました。

## 実装する

### 手順1. フロントエンド:UIの実装

今回、UI側はReact(Next.js)を使って実装しています。

ドラッグ＆ドロップでのファイルアップロードに対応した方が便利だろうと思い、[react-dropzone](https://react-dropzone.js.org/)を使いました。

また、Form自体のPOSTやバリデーションは[react-hook-form](https://react-hook-form.com/jp/)を使っています。

```jsx
const BookForm: React.FC<Props> = ({ onSubmit, onError }) => {
  const [imageUrl, setImageUrl] = useState('')
  const [imageKey, setImageKey] = useState('')
  const { register, handleSubmit, errors } = useForm()
  const onDrop = useCallback((acceptedFiles) => {
    // 後で実装
  }, [])
  const { getRootProps, getInputProps } = useDropzone({ onDrop })

  return (
    <form onSubmit={handleSubmit(onSubmit, onError)}>
      <label className="block mb-4">
        <span>画像</span>
        {imageKey && <img src={imageUrl} className="h-32 m-4" />}
        <div className="border-dashed border-2 h-32 rounded flex justify-center items-center" {...getRootProps()} >
          <input {...getInputProps()} /><p className="block text-gray-400">Drop the files here ...</p>
        </div>
        <input type="hidden" name="key" ref={register({ required: true })} defaultValue={imageKey} />
        <small className="mb-2 text-red-600 block">{errors.key && <span>This field is required</span>}</small>
      </label>
      <input type="submit" value="Save" className="mt-4 px-6 py-2 text-white bg-accent rounded hover:bg-accent-dark" />
    </form>
  )
}

export default BookForm
```

### 手順2. バックエンド:署名付きURLの発行

Rails側でリクエストを受けたときに署名付きURLを作成して返すようにします。

```ruby
class Image
  Aws.config.update(
   region: 'ap-northeast-1' ,
   credentials: Aws::Credentials.new(ENV['AWS_ACCESS_KEY_ID'], ENV['AWS_SECRET_ACCESS_KEY'])
  )

  def self.signed_url(filename, operation)
    signer = Aws::S3::Presigner.new
    signer.presigned_url(operation, bucket: ENV['S3_BUCKET_NAME'], key: filename)
  end
end
```

### 手順3. フロントエンド:ファイルをS3へPOSTし、KeyをRailsへPOSTする

ファイルがドロップされたときのコールバック処理を実装します。

最初にRailsの `/images` へPOSTすることで、署名付きURLを発行します。その署名付きURLへPUTすることでファイルをアップロードします。

アップロード後に `setImageKey` および `setImageUrl` を使って、Reactのstateを更新します。

```javascript
  const onDrop = useCallback((acceptedFiles) => {
    acceptedFiles.forEach(async (file) => {
      const {
        data: { signedUrl, key },
      } = await axios.post('/images')
      await axios.put(signedUrl, file, {
        headers: {
          'Access-Control-Allow-Origin': location.href,
          'Content-Type': file.type,
        },
      })
      const res = await axios.get(`/images/${key}`)
      setImageUrl(res.data.signedUrl)
      setImageKey(key)
    })
  }, [])
```

### 手順4. バックエンド:画像のURLを生成する

画像を表示するときはバックエンド側で画像のURLを生成してフロントエンド側に渡します。

#### 署名付きURLを使用する場合

上述の `Image.signed_url` の第2引数を `:get_object` として呼び出し、フロントエンド側に署名付きURLを発行します。

署名付きURLは期限が限られているので、画像を表示する度に毎回生成しなおす必要があります。URLをどこかに永続化していたり、フロントエンド側でSSGしていたりすると、時間が経つことでリンク切れする懸念があるので注意が必要です。

#### バケットを公開する場合

署名付きURLを使いたくないケースで、バケット自体を公開しても問題ない場合は、直接ObjectのURLを参照することで公開します。今回は前段にCloudFrontを配置して、CDNのURLを返すようにしました。

```ruby
class Image
  # 省略

  def self.cdn_url(filename)
    "#{ENV['CLOUDFRONT_ORIGIN']}/#{filename}"
  end
end
```

## まとめ

Railsだけで開発しているときはActive Storageは非常に便利な機能だったのですが、SPAを開発するシチュエーションではかえって使いづらいと感じました。

署名付きURL自体はS3に限らずAzure Blog StorageやGCP Cloud Storageでも提供されている方法なので、クラウドサービスが変わってもこの方法は利用できそうですね。

![](https://storage.googleapis.com/zenn-user-upload/ydyf0781hx7kw9p8t1nqvugc45lz)
