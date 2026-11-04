"""CAM++ 预训练声纹编码器（借鉴优秀作品思路：换用在 CN-Celeb 2796 人上预训练的
说话人确认模型，替代原先小数据自训的 MFCC+CNN）。

模型：ModelScope iic/speech_campplus_sv_zh-cn_16k-common（中文通用声纹模型，
Fbank 特征 + CAM++ 网络，输出 192 维声纹向量，余弦相似度比对）。
输入：16kHz 单声道 float32 numpy 数组（与阵列音频链路格式一致）。
"""
import os

import numpy as np

_MODEL_ID = 'iic/speech_campplus_sv_zh-cn_16k-common'
# 声纹库与模块同目录，随仓库提供；录入后原地覆盖
_DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        'voiceprint_db_campplus.npz')


class CampplusEncoder:
    """音频 -> L2 归一化声纹向量。管线惰性加载，避免影响接收服务启动。"""

    def __init__(self):
        from modelscope.pipelines import pipeline
        from modelscope.utils.constant import Tasks
        self.pipe = pipeline(task=Tasks.speaker_verification, model=_MODEL_ID)

    def embedding(self, wav):
        """wav: 16kHz 单声道 numpy 数组 -> [192] L2 归一化向量。"""
        wav = np.asarray(wav, dtype=np.float32)
        self.pipe([wav], output_emb=True)
        emb = self.pipe.save_dict['embs'][0]
        return emb / (np.linalg.norm(emb) + 1e-10)


class CampplusDB(CampplusEncoder):
    """声纹库：name -> 平均声纹向量，npz 持久化（与旧 CNN 库文件分开存放）。"""

    def __init__(self, db_path=_DB_PATH, threshold=-1.0):   # 不设阈值：识别到人声即显示最相似的人名
        super().__init__()
        self.db_path = db_path
        self.threshold = threshold
        self.names, self.embeddings = self._load_db()

    def _load_db(self):
        try:
            with np.load(self.db_path) as data:
                return list(data['names']), np.asarray(data['embeddings'])
        except (FileNotFoundError, ValueError):
            return [], np.zeros((0, 192), dtype=np.float32)

    def _save_db(self):
        import tempfile
        fd, tmp = tempfile.mkstemp(suffix='.npz', prefix='vpdb_')
        os.close(fd)
        np.savez(tmp, names=np.array(self.names), embeddings=self.embeddings)
        os.replace(tmp, self.db_path)

    def enroll(self, name, wavs):
        """注册：同一说话人多段语音取平均向量。wavs 为 numpy 数组列表。"""
        embs = np.stack([self.embedding(w) for w in wavs])
        emb = embs.mean(axis=0)
        emb /= np.linalg.norm(emb) + 1e-10
        if name in self.names:
            self.embeddings[self.names.index(name)] = emb
        else:
            self.names.append(name)
            self.embeddings = np.vstack(
                [self.embeddings, emb[None, :].astype(np.float32)])
        self._save_db()
        return name

    def identify(self, wav):
        """1:N 辨认：返回 (best_name, best_score, ok, candidates)。"""
        if not self.names:
            raise RuntimeError('声纹库为空，请先注册')
        emb = self.embedding(wav)
        sims = self.embeddings @ emb
        order = np.argsort(-sims)
        cands = [{'name': self.names[i], 'score': float(sims[i])}
                 for i in order[:3]]
        bi = int(order[0])
        bs = float(sims[bi])
        return self.names[bi], bs, bs >= self.threshold, cands
