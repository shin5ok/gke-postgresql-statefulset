GKE で **Hyperdisk Balanced** を利用するためのカスタム `StorageClass` の YAML 定義と、StatefulSet での利用例です。

---

### 1\. Hyperdisk Balanced 用 StorageClass の YAML（推奨）

クラスタに以下の `StorageClass` を適用します。

```
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: hyperdisk-balanced
provisioner: pd.csi.storage.gke.io
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters:
  type: hyperdisk-balanced
  # 任意: ボリューム作成時の IOPS (未指定時はデフォルト値)
  provisioned-iops-on-create: "10000"
  # 任意: ボリューム作成時のスループット (未指定時はデフォルト値)
  provisioned-throughput-on-create: "250Mi"
```

#### 主なパラメータのポイント

* `provisioner: pd.csi.storage.gke.io`: GKE の Compute Engine Persistent Disk CSI ドライバを指定します。  
* `volumeBindingMode: WaitForFirstConsumer`: Pod がノードにスケジュールされるまでボリュームのプロビジョニングを待機させます（ゾーンの不一致やストレージ非対応ノードへのアタッチ失敗を防ぐため必須）。  
* `allowVolumeExpansion: true`: PVC のサイズ拡張を後から可能にします。  
* `provisioned-iops-on-create` / `provisioned-throughput-on-create`: ディスクサイズとは独立して、初期 IOPS やスループットを指定できます。

### ---

2\. StatefulSet での利用例 (`volumeClaimTemplates`)

作成した `hyperdisk-balanced` を StatefulSet の `volumeClaimTemplates` 内で `storageClassName` に指定します。

```
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres-db
spec:
  serviceName: "postgres-db"
  replicas: 1
  selector:
    matchLabels:
      app: postgres-db
  template:
    metadata:
      labels:
        app: postgres-db
    spec:
      nodeSelector:
	 cloud.google.com/compute-class: Performance
        # N4 シリーズのノードを要求
        cloud.google.com/machine-family: n4
      containers:
      - name: postgres
        image: postgres:16
        env:
        - name: POSTGRES_PASSWORD
          value: "mysecretpassword"
        # ★ CPU とメモリの requests を明示的に指定
        resources:
          requests:
            cpu: "2"
            memory: "8Gi"
          limits:
            cpu: "2"
            memory: "8Gi"
        volumeMounts:
        - name: db-data
          mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
  - metadata:
      name: db-data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      storageClassName: "hyperdisk-balanced"
      resources:
        requests:
          storage: 150Gi
```
