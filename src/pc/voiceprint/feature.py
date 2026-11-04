"""MFCC 特征提取模块。

对应参考项目的"数据预处理"层（其使用 Fbank），本系统按需求改为 MFCC：
音频 -> 单声道/重采样 -> STFT -> Mel 滤波器组 -> 对数能量 -> DCT -> MFCC，
最后做逐语句 CMVN（倒谱均值方差归一化），抑制信道差异。
"""
import subprocess

import numpy as np
import soundfile as sf
import torch
import torchaudio

from configs import Config


def _read_via_ffmpeg(path):
    """soundfile 不支持的容器（m4a/aac 等）走 ffmpeg 解码为 16k 单声道 PCM。"""
    import imageio_ffmpeg
    ff = imageio_ffmpeg.get_ffmpeg_exe()
    raw = subprocess.run(
        [ff, "-v", "error", "-i", path, "-f", "s16le", "-acodec", "pcm_s16le",
         "-ac", "1", "-ar", str(Config.sample_rate), "-"],
        capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0


class MFCCExtractor:
    """音频 -> MFCC 特征，输出形状 [n_mfcc, T]。"""

    def __init__(self, cfg=Config):
        self.cfg = cfg
        self.transform = torchaudio.transforms.MFCC(
            sample_rate=cfg.sample_rate,
            n_mfcc=cfg.n_mfcc,
            melkwargs=dict(
                n_fft=cfg.n_fft,
                win_length=cfg.win_length,
                hop_length=cfg.hop_length,
                n_mels=cfg.n_mels,
                f_min=cfg.f_min,
                f_max=cfg.f_max,
                center=True,
                power=2.0,
            ),
        )

    def load_audio(self, path):
        """读取音频 -> 单声道 float32 tensor，并重采样到目标采样率。"""
        try:
            data, sr = sf.read(path, dtype="float32", always_2d=True)
            wav = torch.from_numpy(data.mean(axis=1))  # 多声道混合为单声道
        except sf.LibsndfileError:
            wav = torch.from_numpy(_read_via_ffmpeg(path))  # m4a 等容器走 ffmpeg
            sr = self.cfg.sample_rate
        if sr != self.cfg.sample_rate:
            wav = torchaudio.functional.resample(
                wav.unsqueeze(0), sr, self.cfg.sample_rate
            ).squeeze(0)
        return wav

    def __call__(self, wav):
        """wav: [num_samples] -> mfcc: [n_mfcc, T]，含 CMVN 归一化。"""
        if wav.dim() == 1:
            wav = wav.unsqueeze(0)
        mfcc = self.transform(wav).squeeze(0)
        mean = mfcc.mean(dim=1, keepdim=True)
        std = mfcc.std(dim=1, keepdim=True).clamp_min(1e-5)
        return (mfcc - mean) / std

    def from_file(self, path):
        return self(self.load_audio(path))
